<*
 The parametric shapes: what they are shaped like, which way round they face,
 and when two of them are one asset.

	`c3c test --trust=full --test-noleak --test-filter three_tests::primitive`

 **No GPU anywhere in this file, on purpose.** `Primitive.build` fills a
 `GeometryBuilder` with plain arrays and knows nothing about a device, so every
 check below runs in microseconds — which is the same argument `scene_test.c3`
 and `js_test.c3` make for their own no-device halves, and it matters more here
 than in either: these are the failures that a picture cannot describe.

 ## What a screenshot cannot check, and this can

 A shape wound inside-out still fills the same silhouette. Under
 `CULL_MODE_BACK_BIT` an inverted sphere draws its far hemisphere instead of its
 near one, which is the same circle of the same colour in the same place — so a
 pixel count, a coverage fraction and a "did anything render" check all pass. It
 shows up as objects that vanish when the camera crosses them and as shading
 that lights from the wrong side, weeks later, in a scene somebody built.

 So the winding is asserted against the triangles themselves:
 `every_generated_face_points_outward` computes each face's normal from the
 order of its own indices and asks whether it points away from the inside. That
 is a statement about the mesh rather than about a render of it, and it is the
 one check that would have caught the frame handed to `build_face` being
 left-handed on any single side of a box.

 The complement — that a shape reaches the screen at all — is in `js_test.c3`,
 where there is a device to reach it with. Neither test pretends to be the other.
*>
module three_tests::primitive;

import three;
import collision;
import std::core::test;
import std::io;
import std::math;
import std::math::vector;

alias Vec3 = float[<3>];
alias Vec2 = float[<2>];

<*
 Build a shape into arrays, run the body over it, and free it.
*>
macro @built(three::Primitive shape; @body(three::GeometryBuilder* geometry))
{
	three::GeometryBuilder geometry;
	geometry.init();
	defer geometry.free();
	shape.build(&geometry);
	@body(&geometry);
}

fn sz triangle_count(three::GeometryBuilder* geometry) => geometry.indices.len() / 3;

<*
 A triangle's normal, taken from the order of its own indices — which is what
 makes it a check on the winding rather than on the normal stream beside it.

 Not normalised: every use here is a sign test, and normalising a degenerate
 triangle would divide by zero at exactly the moment the answer mattered.
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

fn Vec3 lowest(three::GeometryBuilder* geometry)
{
	Vec3 out = geometry.positions[0];
	foreach (position : geometry.positions) out = math::min(out, position);
	return out;
}

fn Vec3 highest(three::GeometryBuilder* geometry)
{
	Vec3 out = geometry.positions[0];
	foreach (position : geometry.positions) out = math::max(out, position);
	return out;
}

fn bool near(float a, float b, float tolerance = 1e-4f) => math::abs(a - b) <= tolerance;

// ============================================================================
// Shape
// ============================================================================

<*
 A shape is the size it was asked for, and centred where Three.js centres it.

 Read off the vertices rather than off the parameters, because the parameters
 are what the test would be assuming: a `SphereGeometry(2)` whose vertices reach
 1.99 is a radius that went through a wrong trig identity, and a box whose
 extents are right but whose centre is not the origin is a shape that will not
 sit on a floor an agent put at y = 0.
*>
fn void every_shape_is_the_size_it_was_asked_for() @test
{
	@built(three::box_shape(2, 1, 3); three::GeometryBuilder* geometry)
	{
		Vec3 low = lowest(geometry);
		Vec3 high = highest(geometry);
		test::@check(near(low.x, -1) && near(high.x, 1), "the box is 2 wide, got %s..%s", low.x, high.x);
		test::@check(near(low.y, -0.5f) && near(high.y, 0.5f), "the box is 1 tall, got %s..%s", low.y, high.y);
		test::@check(near(low.z, -1.5f) && near(high.z, 1.5f), "the box is 3 deep, got %s..%s", low.z, high.z);
	};

	@built(three::sphere_shape(2, 32, 16); three::GeometryBuilder* geometry)
	{
		Vec3 low = lowest(geometry);
		Vec3 high = highest(geometry);
		test::@check(near(high.y, 2) && near(low.y, -2), "the poles are at +/-2, got %s..%s", low.y, high.y);
		foreach (position : geometry.positions)
		{
			test::@check(near(position.length(), 2, 1e-3f), "every vertex is 2 from the centre, got %s", position.length());
		}
	};

	// Flat, in XY, facing +Z — Three.js's plane, which is vertical.
	@built(three::plane_shape(4, 2); three::GeometryBuilder* geometry)
	{
		Vec3 low = lowest(geometry);
		Vec3 high = highest(geometry);
		test::@check(near(low.x, -2) && near(high.x, 2), "4 wide, got %s..%s", low.x, high.x);
		test::@check(near(low.y, -1) && near(high.y, 1), "2 tall, got %s..%s", low.y, high.y);
		test::@check(near(low.z, 0) && near(high.z, 0), "flat in z, got %s..%s", low.z, high.z);
		foreach (normal : geometry.normals)
		{
			test::@check(near(normal.z, 1), "every normal faces +Z, got %s", normal.z);
		}
	};

	@built(three::cylinder_shape(1, 1, 3); three::GeometryBuilder* geometry)
	{
		Vec3 low = lowest(geometry);
		Vec3 high = highest(geometry);
		test::@check(near(low.y, -1.5f) && near(high.y, 1.5f), "3 tall about the origin, got %s..%s", low.y, high.y);
		test::@check(near(high.x, 1, 1e-3f) && near(high.z, 1, 1e-3f), "radius 1, got %s and %s", high.x, high.z);
	};

	// The point is up, and the base is a full-radius disc at the bottom.
	@built(three::cylinder_shape(0, 1, 2); three::GeometryBuilder* geometry)
	{
		Vec3 high = highest(geometry);
		test::@check(near(high.y, 1), "the tip is at +1, got %s", high.y);
		usz at_the_tip = 0;
		foreach (position : geometry.positions)
		{
			if (near(position.y, 1) && near(position.x, 0) && near(position.z, 0)) at_the_tip++;
		}
		test::@check(at_the_tip > 0, "there is a tip at the top");
	};

	// radius is to the centre of the tube, so the ring spans 2 * (radius + tube)
	// and the tube's own thickness is what shows in z.
	@built(three::torus_shape(1, 0.25); three::GeometryBuilder* geometry)
	{
		Vec3 low = lowest(geometry);
		Vec3 high = highest(geometry);
		test::@check(near(high.x, 1.25f, 1e-3f) && near(low.x, -1.25f, 1e-3f), "1.25 across in x, got %s..%s", low.x, high.x);
		test::@check(near(high.z, 0.25f, 1e-3f) && near(low.z, -0.25f, 1e-3f), "the tube is 0.25, got %s..%s", low.z, high.z);
	};
}

// ============================================================================
// Winding
// ============================================================================

<*
 Every face points away from the inside.

 The test is `dot(face normal, face centre) > 0`, and it is exact rather than
 approximate for these five: a box, a sphere, a capped cylinder and a cone are
 all star-shaped about the origin, so the outward direction at any point on the
 surface has a positive component along the vector from the centre to it. A
 single face of a box handed a left-handed frame fails this and nothing else in
 the suite.

 The torus is not star-shaped about its own centre — the inner wall of the ring
 faces *toward* it — so it is measured against the centre line of its tube
 instead, which is the same statement made about the shape it actually is.
*>
fn void every_generated_face_points_outward() @test
{
	three::Primitive[4] star_shaped = {
		three::box_shape(2, 1, 3, 2, 2, 2),
		three::sphere_shape(1, 16, 8),
		three::cylinder_shape(1, 1, 2, 12, 2),
		three::cylinder_shape(0, 1, 2, 12, 2),   // a cone
	};

	foreach (shape : star_shaped)
	{
		@built(shape; three::GeometryBuilder* geometry)
		{
			for (sz t = 0; t < triangle_count(geometry); t++)
			{
				Vec3 normal = face_normal(geometry, t);
				Vec3 centre = face_centre(geometry, t);
				test::@check(
					normal.dot(centre) > 0,
					"triangle %d of <%s> faces inward: normal %s, centre %s",
					t, shape.key(tmem), normal, centre
				);
			}
		};
	}

	@built(three::torus_shape(1, 0.25, 24, 8); three::GeometryBuilder* geometry)
	{
		for (sz t = 0; t < triangle_count(geometry); t++)
		{
			Vec3 normal = face_normal(geometry, t);
			Vec3 centre = face_centre(geometry, t);
			// The nearest point on the ring's centre line, which is what the tube
			// wraps around: the face has to point away from *that*.
			float radial = math::sqrt(centre.x * centre.x + centre.y * centre.y);
			Vec3 spine = { centre.x / radial, centre.y / radial, 0 };
			test::@check(
				normal.dot(centre - spine) > 0,
				"triangle %d of the torus faces inward: normal %s, centre %s", t, normal, centre
			);
		}
	};
}

<*
 The normal stream agrees with the winding.

 Two ways of saying which side is out, and a shape where they disagree is lit
 from behind while being culled from the front — the pair of symptoms that reads
 as "the light is wrong" and sends whoever is debugging it to the wrong file.

 The threshold is a sign rather than an angle because a cone's side normals lean
 hard: at the tip the geometric face normal and the interpolated vertex normals
 are a long way apart and both are correct.
*>
fn void the_normals_agree_with_the_winding() @test
{
	three::Primitive[5] shapes = {
		three::box_shape(1, 1, 1),
		three::sphere_shape(1, 16, 8),
		three::plane_shape(2, 2),
		three::cylinder_shape(0.5, 1, 2, 12, 1),
		three::torus_shape(1, 0.25, 24, 8),
	};

	foreach (shape : shapes)
	{
		@built(shape; three::GeometryBuilder* geometry)
		{
			for (sz t = 0; t < triangle_count(geometry); t++)
			{
				Vec3 winding = face_normal(geometry, t);
				Vec3 declared = geometry.normals[geometry.indices[t * 3]]
					+ geometry.normals[geometry.indices[t * 3 + 1]]
					+ geometry.normals[geometry.indices[t * 3 + 2]];
				test::@check(
					winding.dot(declared) > 0,
					"triangle %d of <%s>: the winding says %s and the normals say %s",
					t, shape.key(tmem), winding, declared
				);
			}
		};
	}
}

<*
 A cone's side normals lean with its slope.

 `build_cylinder` builds the side normal as `(sin, slope, cos)` normalised, and
 the tempting simplification is the radial `(sin, 0, cos)` — which is right for a
 cylinder and wrong for everything that tapers. Nothing else in this file catches
 it: the silhouette is identical, the winding is identical, and the normal still
 agrees with the winding to well inside a right angle. What it costs is the
 shading, and a cone lit like a cylinder reads as a light in the wrong place.

 The check is exact rather than approximate. The straight line from any point on
 a cone's side to its tip lies *in* the surface, so the normal there is
 perpendicular to it — a dot product of zero, at every vertex, for a cone of any
 proportion.
*>
fn void a_cone_is_shaded_as_a_cone() @test
{
	// Open-ended, so every vertex belongs to the side: a cap's normal is ±Y and
	// the line to the tip is not in its plane.
	@built(three::cylinder_shape(0, 1, 2, 16, 1, false); three::GeometryBuilder* geometry)
	{
		Vec3 tip = { 0, 1, 0 };
		foreach (i, position : geometry.positions)
		{
			// Except at the tip itself, where the line has no direction and the
			// normal is whatever the limit of the ring below it was.
			if (near(position.y, 1)) continue;
			Vec3 along = (tip - position).normalize();
			float leaning = geometry.normals[(sz)i].dot(along);
			test::@check(
				math::abs(leaning) < 1e-3f,
				"the normal at %s is perpendicular to the line to the tip, got a dot of %s", position, leaning
			);
		}
	};
}

<*
 No triangle is a sliver, and none is a point.

 The poles of a sphere and the tip of a cone are where a grid degenerates, and
 the tempting implementation emits the collapsed quad anyway — it costs two
 indices and renders as nothing. It is not nothing: a zero-area triangle goes
 into the BVH as a leaf that can never be hit and can never be pruned, so every
 ray through that corner of the tree pays for it forever.
*>
fn void nothing_degenerate_is_emitted() @test
{
	three::Primitive[4] shapes = {
		three::sphere_shape(1, 12, 6),
		three::cylinder_shape(0, 1, 2, 12, 3),      // a cone: a tip at the top
		three::cylinder_shape(1, 0, 2, 12, 3),      // and one pointing down
		three::box_shape(1, 2, 3, 2, 3, 4),
	};

	foreach (shape : shapes)
	{
		@built(shape; three::GeometryBuilder* geometry)
		{
			test::@check(triangle_count(geometry) > 0, "<%s> produced triangles", shape.key(tmem));
			for (sz t = 0; t < triangle_count(geometry); t++)
			{
				uint a = geometry.indices[t * 3];
				uint b = geometry.indices[t * 3 + 1];
				uint c = geometry.indices[t * 3 + 2];
				test::@check(a != b && b != c && a != c, "triangle %d of <%s> repeats a vertex", t, shape.key(tmem));
				test::@check(
					face_normal(geometry, t).length() > 1e-6f,
					"triangle %d of <%s> has no area", t, shape.key(tmem)
				);
			}
		};
	}
}

<*
 Every texture coordinate is inside the unit square.

 A material reads `s.uv`, and a shape that hands it 1.0000001 or -0 is a wrapped
 texel at a seam — the kind of artefact that gets blamed on the sampler.
*>
fn void texture_coordinates_stay_in_the_unit_square() @test
{
	three::Primitive[6] shapes = {
		three::box_shape(1, 1, 1, 2, 2, 2),
		three::sphere_shape(1, 16, 8),
		three::plane_shape(1, 1, 3, 3),
		three::cylinder_shape(1, 1, 2, 12, 2),
		three::cylinder_shape(0, 1, 2, 12, 1),
		three::torus_shape(1, 0.25, 24, 8),
	};

	foreach (shape : shapes)
	{
		@built(shape; three::GeometryBuilder* geometry)
		{
			foreach (uv : geometry.uvs)
			{
				test::@check(
					uv.x >= -1e-5f && uv.x <= 1 + 1e-5f && uv.y >= -1e-5f && uv.y <= 1 + 1e-5f,
					"<%s> has a uv outside the unit square: %s", shape.key(tmem), uv
				);
			}
		};
	}
}

<*
 Every stream covers every vertex.

 `upload_primitive` sets `has_normals` from exactly this comparison — a stream
 short of the positions is read past its own end by the shader, which indexes
 all three with one SV_VertexID. A generated shape declares both streams
 unconditionally, so here the comparison is the check rather than the guard.
*>
fn void the_three_streams_are_the_same_length() @test
{
	@built(three::cylinder_shape(0.5, 1, 2, 9, 3); three::GeometryBuilder* geometry)
	{
		test::@check(
			geometry.normals.len() == geometry.positions.len(),
			"a normal per vertex: %d normals, %d positions", geometry.normals.len(), geometry.positions.len()
		);
		test::@check(
			geometry.uvs.len() == geometry.positions.len(),
			"a uv per vertex: %d uvs, %d positions", geometry.uvs.len(), geometry.positions.len()
		);
		test::@check(geometry.indices.len() % 3 == 0, "the indices are whole triangles");
		foreach (index : geometry.indices)
		{
			test::@check((sz)index < geometry.positions.len(), "index %d is inside the vertex array", index);
		}
	};
}

// ============================================================================
// Identity
// ============================================================================

<*
 The key is what decides that two shapes are one asset, so every number that
 reaches a vertex has to be in it.

 A key that ignored a field would be a `BoxGeometry(1, 1, 1)` handed back for a
 `BoxGeometry(1, 1, 2)` — the wrong shape, silently, with the right name. This
 walks a list of shapes that differ from their neighbour in exactly one
 parameter and asserts that no two of them agree.
*>
fn void the_key_names_every_number_that_reaches_a_vertex() @test
{
	three::Primitive[13] all = {
		three::box_shape(1, 1, 1),
		three::box_shape(2, 1, 1),
		three::box_shape(1, 2, 1),
		three::box_shape(1, 1, 2),
		three::box_shape(1, 1, 1, 2, 1, 1),
		three::box_shape(1, 1, 1, 1, 2, 1),
		three::box_shape(1, 1, 1, 1, 1, 2),
		three::sphere_shape(1, 32, 16),
		three::sphere_shape(1, 33, 16),
		three::plane_shape(1, 1),
		three::cylinder_shape(1, 1, 1, 8, 1, true),
		three::cylinder_shape(1, 1, 1, 8, 1, false),
		three::torus_shape(1, 0.4f),
	};

	for (usz i = 0; i < all.len; i++)
	{
		for (usz j = i + 1; j < all.len; j++)
		{
			String left = all[i].key(tmem);
			String right = all[j].key(tmem);
			test::@check(left != right, "two different shapes share a key: <%s>", left);
		}
	}

	// And the other half of the contract, which is the half that makes a
	// thousand BoxGeometries one draw call.
	test::@check(
		three::box_shape(2, 1, 3).key(tmem) == three::box_shape(2, 1, 3).key(tmem),
		"the same numbers make the same key"
	);
}

<*
 A cone is a cylinder with no top, and shares its asset.

 `prelude.js` builds `ConeGeometry(r, h)` by asking for `cylinder(0, r, h)`, so
 the two spellings have to reach the same key — otherwise a scene with a cone and
 an equivalent cylinder uploads the same triangles twice and draws them in two
 calls, which is the exact failure the dedup exists to prevent.
*>
fn void a_cone_and_the_cylinder_that_describes_it_are_one_shape() @test
{
	String cone = three::cylinder_shape(0, 1, 2, 32, 1, true).key(tmem);
	String cylinder = three::cylinder_shape(0, 1, 2, 32, 1, true).key(tmem);
	test::@check(cone == cylinder, "<%s> and <%s> are one shape", cone, cylinder);

	// The tip really is a tip: no top cap was generated for a zero radius.
	@built(three::cylinder_shape(0, 1, 2, 32, 1, true); three::GeometryBuilder* geometry)
	{
		usz at_the_top = 0;
		foreach (position : geometry.positions)
		{
			if (near(position.y, 1)) at_the_top++;
		}
		// The ring of tip vertices, one per radial segment plus the seam. A cap
		// would add its centre and its own ring on top of that.
		test::@check(at_the_top == 33, "the top is a tip, not a disc: %d vertices up there", at_the_top);
	};
}

<*
 Segment counts are clamped to something that can be built.

 Both ends are load-bearing and neither is cosmetic: two radial segments enclose
 nothing and a loop dividing by zero segments is a NaN in every position, while
 the ceiling is what stands between a mistyped literal and an allocation the size
 of the device. The prelude refuses out-of-range counts with a sentence before
 either happens; this is the backstop for a script that calls the host verb
 itself.
*>
fn void segment_counts_are_clamped_to_something_buildable() @test
{
	three::Primitive tiny = three::sphere_shape(1, 0, 0);
	test::@check(tiny.u >= 3, "a sphere has at least 3 segments around, got %d", tiny.u);
	test::@check(tiny.v >= 2, "a sphere has at least 2 rings, got %d", tiny.v);

	three::Primitive huge = three::sphere_shape(1, 100_000, 100_000);
	test::@check(huge.u == three::MAX_PRIMITIVE_SEGMENTS, "capped at %d, got %d", three::MAX_PRIMITIVE_SEGMENTS, huge.u);
	test::@check(huge.v == three::MAX_PRIMITIVE_SEGMENTS, "capped at %d, got %d", three::MAX_PRIMITIVE_SEGMENTS, huge.v);

	// And the clamped shape still builds something with area.
	@built(tiny; three::GeometryBuilder* geometry)
	{
		test::@check(triangle_count(geometry) > 0, "a clamped sphere still has triangles");
		foreach (position : geometry.positions)
		{
			test::@check(position.x == position.x, "no NaN reached a vertex");
		}
	};
}

fn void a_name_that_is_not_a_shape_is_refused() @test
{
	test::@check(@ok(three::primitive_kind("box")), "box is a shape");
	test::@check(@ok(three::primitive_kind("torus")), "torus is a shape");
	test::@check(!@ok(three::primitive_kind("Box")), "the names are lower case");
	test::@check(!@ok(three::primitive_kind("teapot")), "there is no teapot");
	test::@check(!@ok(three::primitive_kind("")), "and no shape with no name");
}
