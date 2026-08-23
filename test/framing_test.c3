<*
 `Camera.frame_bounds`, and whether the thing it framed is actually on screen.

	`c3c test --trust=full --test-noleak --test-filter three_tests::framing`

 No GPU, no window and no scene: this is six numbers in and a `Camera` out, so
 everything here runs in microseconds.

 **Assert on where the corners landed, not on the distance that put them
 there.** A framing bug is not a crash and not a validation message — it is a
 picture that is too small, or one with a corner just off the edge, and both
 survive every existing test in this repository because a triangle at a third of
 the frame renders exactly as correctly as one that fills it. So the checks here
 project the box's own corners through the camera's view-projection and say
 where in the frame they came out, which is the claim a person is making when
 they say `frameAll` is zoomed out too far.

 The regression this pins: until M6 the distance came from the box's *corner
 sphere*, fitted to the vertical half-angle alone and then multiplied by 1.25.
 Compounded, that framed a 16:9 view of a wide flat scene at about a third of
 the frame width, and — the part that was wrong rather than merely loose — never
 fitted the horizontal at all, so a portrait viewport ran off its own sides.
*>
module three_tests::framing;

import three;
import std::core::test;
import std::math;
import std::math::vector;
import std::math::matrix;

// Deliberately not 1:1, so an x/y mix-up cannot cancel out. 16:9 is also the
// shape `--width`/`--height` default to, which is the case the fix is about.
const float WIDE = 1280.0 / 720.0;
// Taller than it is wide: here the *horizontal* is the narrower half-angle, and
// fitting the vertical alone — what the old code did unconditionally — leaves
// the sides unfitted.
const float TALL = 720.0 / 1280.0;

<*
 Where a world point lands in normalized device coordinates.

 x and y run -1..1 across the frame. Anything outside that is off screen, which
 is the whole vocabulary these tests need.
*>
fn float[<2>] project(three::Camera* camera, float aspect, Vec3 world)
{
	Matrix4f vp = camera.view_projection(aspect);
	float[<4>] clip = vp * (float[<4>]) { world.x, world.y, world.z, 1.0 };
	// Behind the eye. Returned as a coordinate far outside the frame rather than
	// divided by a negative w, which would fold it back into view and read as a
	// pass.
	if (clip.w <= 0.0f) return { 1000, 1000 };
	return { clip.x / clip.w, clip.y / clip.w };
}

<*
 The eight corners of a box, in the order the bit pattern gives them.

 The same enumeration `frame_bounds` walks, so a fit that missed a corner and a
 test that never checked it cannot agree by construction.
*>
fn Vec3[8] corners(Vec3 min, Vec3 max)
{
	Vec3[8] out;
	for (int i = 0; i < 8; i++)
	{
		out[i] = {
			(i & 1) != 0 ? max.x : min.x,
			(i & 2) != 0 ? max.y : min.y,
			(i & 4) != 0 ? max.z : min.z,
		};
	}
	return out;
}

<*
 How close to the edge of the frame the outermost corner got.

 1.0 is touching it. **Not the silhouette's span**, which is the obvious metric
 and the wrong one: an exact fit puts the single worst corner on the frustum
 wall, and on a box seen from an angle the corner at the other end of the same
 screen axis is a different corner at a different depth, so it projects nowhere
 near the opposite edge. A cube framed perfectly at 16:9 spans 0.78 of the
 frame's height for that reason alone, and a test written against the span would
 be reporting perspective foreshortening as slack in the fit.

 What the fit actually promises is this number, and it is the one that collapses
 when the distance is too large.
*>
fn float reach(three::Camera* camera, float aspect, Vec3 min, Vec3 max)
{
	float worst = 0.0f;
	foreach (corner : corners(min, max))
	{
		float[<2>] ndc = project(camera, aspect, corner);
		worst = math::max(worst, math::max(math::abs(ndc.x), math::abs(ndc.y)));
	}
	return worst;
}

fn three::Camera framed(Vec3 min, Vec3 max, float aspect)
{
	three::Camera camera = three::default_camera();
	camera.frame_bounds(min, max, aspect);
	return camera;
}

// The shapes worth fitting, and why each one is here.
struct Shape
{
	String name;
	Vec3 min;
	Vec3 max;
}

const Shape[*] SHAPES = {
	// A cube: the case where the corner sphere overshoots by the full sqrt(3).
	{ "a cube",              { -5, -5, -5 },      { 5, 5, 5 } },
	// Wide and flat, centred: a ground plane with something standing on it,
	// which is what a scene built by a script usually is.
	{ "a wide flat scene",   { -10, 0, -10 },     { 10, 5.7, 10 } },
	// Long and thin along one axis: the shape whose projected width swings most
	// as the turntable turns.
	{ "a long thin scene",   { -30, -0.5, -1 },   { 30, 0.5, 1 } },
	// Tall and narrow — the same problem stood on its end.
	{ "a tower",             { -1, 0, -1 },       { 1, 40, 1 } },
	// Off the origin, so a fit that framed the box's centre correctly but
	// forgot to move the target would put it off screen.
	{ "a box far off centre",{ 100, 20, -60 },    { 110, 26, -52 } },
	// Smaller than the near plane's usual neighbourhood.
	{ "a tiny box",          { -0.01, -0.01, -0.01 }, { 0.01, 0.01, 0.01 } },
};

// The orientations a fit has to hold at. `frame_bounds` fits the orientation it
// is called at, so each of these is its own fit, not one fit re-examined.
const float[2][*] ANGLES = {
	{ 0, 0 }, { 35, 20 }, { 90, 0 }, { 180, 45 }, { -70, -30 }, { 45, 85 },
};

<*
 Everything the camera was pointed at is inside the frame.

 The floor of the whole exercise: whatever else a fit does, no corner of the box
 it was handed may be off screen. Checked across six shapes, six orientations
 and three aspect ratios, because the old code passed this at 16:9 and failed it
 in portrait — a fit that only ever consults the vertical half-angle is correct
 exactly while the vertical is the narrower one.
*>
fn void every_corner_is_inside_the_frame() @test
{
	float[*] aspects = { WIDE, 1.0, TALL };
	foreach (shape : SHAPES)
	{
		foreach (aspect : aspects)
		{
			foreach (angle : ANGLES)
			{
				three::Camera camera = three::default_camera();
				camera.yaw = angle[0];
				camera.pitch = angle[1];
				camera.frame_bounds(shape.min, shape.max, aspect);

				foreach (i, corner : corners(shape.min, shape.max))
				{
					float[<2>] ndc = project(&camera, aspect, corner);
					// A whisker of tolerance: the fit lands the binding corner
					// exactly on the wall before the margin pulls it in, and an
					// exact 1.0 comparison would be testing float rounding.
					test::@check(
						math::abs(ndc.x) <= 1.0f && math::abs(ndc.y) <= 1.0f,
						"%s at yaw %s pitch %s aspect %s: corner %d landed at (%s, %s), outside the frame",
						shape.name, angle[0], angle[1], aspect, i, ndc.x, ndc.y
					);
				}
			}
		}
	}
}

<*
 The subject fills the frame it was framed for.

 This is the bug, stated as a number, and it is the test that would have caught
 it. The old fit left the outermost corner of a cube at 0.73 of the way to the
 edge and the outermost corner of a wide flat scene at 0.51 — which is what
 "`frameAll` is zoomed out too far" measures out to, and neither is a failure any
 other check in this repository can see.

 The threshold is 0.85 and the fit lands at about 0.94: an exact fit would put
 the binding corner at exactly 1.0, and `frame_bounds` then pulls back by its 5%
 margin to keep the silhouette off the edge. The gap between 0.85 and 0.94 is
 room for that margin to be retuned without rewriting this; the gap between 0.85
 and the old code's 0.51 is what the test is for.
*>
fn void the_subject_fills_the_frame() @test
{
	float[*] aspects = { WIDE, 1.0, TALL };
	foreach (shape : SHAPES)
	{
		foreach (aspect : aspects)
		{
			foreach (angle : ANGLES)
			{
				three::Camera camera = three::default_camera();
				camera.yaw = angle[0];
				camera.pitch = angle[1];
				camera.frame_bounds(shape.min, shape.max, aspect);

				float got = reach(&camera, aspect, shape.min, shape.max);
				test::@check(
					got >= 0.85f,
					"%s at yaw %s pitch %s aspect %s: the outermost corner only reached %s of the way to the frame edge — the fit is backed off too far",
					shape.name, angle[0], angle[1], aspect, got
				);
			}
		}
	}
}

<*
 A wide frame is framed more closely than a square one.

 The direct statement of what the aspect argument buys. Widening the viewport
 adds horizontal room and takes none away, so the distance needed can only fall
 — and the old code, which never read the aspect, returned the same distance for
 every shape of frame.
*>
fn void a_wider_frame_gets_closer() @test
{
	// Monotonic for every shape, and *strictly* closer for at least one. Without
	// the second half this passes against a `frame_bounds` that ignores its aspect
	// argument altogether, which is exactly the code it exists to rule out — every
	// comparison is then an equality and every `<=` is satisfied.
	bool any_strictly_closer = false;
	foreach (shape : SHAPES)
	{
		three::Camera square = framed(shape.min, shape.max, 1.0);
		three::Camera wide = framed(shape.min, shape.max, WIDE);
		test::@check(
			wide.distance <= square.distance + 0.0001f,
			"%s: a 16:9 fit backed off to %s, further than the square fit's %s",
			shape.name, wide.distance, square.distance
		);
		if (wide.distance < square.distance - 0.0001f) any_strictly_closer = true;
	}
	test::@check(
		any_strictly_closer,
		"no shape was framed closer on a 16:9 frame than on a square one — the aspect is being ignored"
	);
}

<*
 A portrait frame fits its narrow axis.

 The half of the old behaviour that was wrong rather than loose. `frame_bounds`
 used to fit the vertical half-angle unconditionally, on the reasoning that the
 vertical is the one the projection is specified by — true, but it is only the
 *narrower* axis while the frame is wider than it is tall. Turn the viewport on
 its end and the unfitted horizontal is the one that clips.

 Asserted as an inequality against the square fit rather than by re-checking the
 corners, so that this keeps saying something specific if the tolerance in
 `every_corner_is_inside_the_frame` is ever loosened.
*>
fn void a_portrait_frame_backs_off_further() @test
{
	bool any_strictly_further = false;
	foreach (shape : SHAPES)
	{
		three::Camera square = framed(shape.min, shape.max, 1.0);
		three::Camera tall = framed(shape.min, shape.max, TALL);
		test::@check(
			tall.distance >= square.distance - 0.0001f,
			"%s: a portrait fit stopped at %s, closer than the square fit's %s — its narrow axis is unfitted",
			shape.name, tall.distance, square.distance
		);
		if (tall.distance > square.distance + 0.0001f) any_strictly_further = true;
	}
	// As above: the equality case is what the old code did, so it has to be a
	// failure here rather than a pass.
	test::@check(
		any_strictly_further,
		"no shape was framed further back on a portrait frame than on a square one — the aspect is being ignored"
	);
}

<*
 The target is the middle of the box, wherever the box is.

 Cheap, and it catches the framing bug that survives every coverage check: a fit
 that gets the distance right and the target wrong is centred on nothing.
*>
fn void the_camera_looks_at_the_middle_of_the_box() @test
{
	foreach (shape : SHAPES)
	{
		three::Camera camera = framed(shape.min, shape.max, WIDE);
		Vec3 centre = (shape.min + shape.max) * 0.5f;
		test::@check(
			(camera.target - centre).length() < 0.001f,
			"%s: the camera is aimed at (%s, %s, %s), not the box's centre (%s, %s, %s)",
			shape.name,
			camera.target.x, camera.target.y, camera.target.z,
			centre.x, centre.y, centre.z
		);
	}
}

<*
 A box with no size at all still leaves a camera somebody can render with.

 An empty scene answers with a degenerate box, and `frameAll` on it used to be
 held up by a `radius = 1` fallback. The failure being guarded against is not an
 exception — it is a zero or NaN distance, which puts the eye inside the target
 and renders an empty frame that says nothing about why.
*>
fn void a_degenerate_box_still_gives_a_usable_camera() @test
{
	Vec3[2][*] degenerate = {
		// A single point.
		{ { 0, 0, 0 }, { 0, 0, 0 } },
		// A point away from the origin, so a fallback that forgot the target
		// would be caught.
		{ { 7, -3, 2 }, { 7, -3, 2 } },
		// Flat in one axis: a ground plane with nothing on it.
		{ { -4, 0, -4 }, { 4, 0, 4 } },
		// Flat in two: a line.
		{ { -4, 0, 0 }, { 4, 0, 0 } },
	};

	foreach (box : degenerate)
	{
		three::Camera camera = framed(box[0], box[1], WIDE);
		test::@check(
			camera.distance > 0.0f && camera.distance < 1e9f,
			"a degenerate box gave a distance of %s", camera.distance
		);
		test::@check(
			camera.near_plane > 0.0f && camera.far_plane > camera.near_plane,
			"a degenerate box gave planes near %s far %s", camera.near_plane, camera.far_plane
		);
		// The eye has to end up somewhere other than the point it is looking at.
		Vec3 eye = camera.eye();
		test::@check(
			(eye - camera.target).length() > 0.0f,
			"the eye and the target coincide, so the view matrix is degenerate"
		);
	}
}

<*
 An aspect that is not a number is read as "no aspect given".

 A render target measured at zero height divides to a NaN, and NaN fails every
 comparison — so the `<= 0` guard this replaced would have waved it through into
 the horizontal half-angle and made the entire fit NaN. What that looks like is
 an empty frame, which reads as a broken scene rather than as a broken camera.
*>
fn void a_nonsense_aspect_falls_back_to_square() @test
{
	Vec3 min = { -10, 0, -10 };
	Vec3 max = { 10, 5.7, 10 };
	three::Camera square = framed(min, max, 1.0);

	float zero = 0.0f;
	float[*] nonsense = { 0.0, -3.0, zero / zero };
	foreach (aspect : nonsense)
	{
		three::Camera camera = framed(min, max, aspect);
		test::@check(
			math::abs(camera.distance - square.distance) < 0.001f,
			"an aspect of %s gave a distance of %s; the square fit is %s",
			aspect, camera.distance, square.distance
		);
	}
}

<*
 Every corner is in front of the far plane, and none is inside the near one.

 Framing that puts the geometry outside the depth range renders an empty frame
 with nothing to say about it — the exact failure `instances_land_where_their_
 transforms_say` in `scene_test.c3` documents as the trap of setting a distance
 by hand. `frame_bounds` derives both planes from the distance it chose, so the
 two have to be checked together or not at all.
*>
fn void the_depth_range_covers_the_box() @test
{
	foreach (shape : SHAPES)
	{
		foreach (angle : ANGLES)
		{
			three::Camera camera = three::default_camera();
			camera.yaw = angle[0];
			camera.pitch = angle[1];
			camera.frame_bounds(shape.min, shape.max, WIDE);

			Vec3 eye = camera.eye();
			Vec3 forward = (camera.target - eye).normalize();
			foreach (i, corner : corners(shape.min, shape.max))
			{
				// Depth along the view axis, which is what the planes cut on —
				// not the straight-line distance to the eye.
				float depth = (corner - eye).dot(forward);
				test::@check(
					depth >= camera.near_plane && depth <= camera.far_plane,
					"%s at yaw %s pitch %s: corner %d sits at depth %s, outside near %s / far %s",
					shape.name, angle[0], angle[1], i, depth, camera.near_plane, camera.far_plane
				);
			}
		}
	}
}

// ============================================================================
// A boom of zero length, and what follows something (plan.md §17)
// ============================================================================

<*
 First person is `distance` at zero, and the view matrix survives it.

 `look_at`'s forward vector is `target - eye`, which at distance zero is the zero
 vector and a matrix of NaN — the same failure the pitch clamp exists to avoid at
 the pole, and it fails the same silent way: an empty frame, which reads as "the
 scene is gone" rather than as "the camera is degenerate". So the direction comes
 from the orbit angles instead.

 Asserted on where a probe lands rather than on the matrix, because "not NaN" is
 satisfied by a great many matrices that point the wrong way.
*>
fn void a_zero_boom_looks_along_the_orbit_angles() @test
{
	three::Camera camera = three::default_camera();
	camera.target = { 0, 0, 0 };
	camera.distance = 0;
	// Straight down -Z, level: yaw 0 puts the eye on +Z looking back at the
	// origin, so at zero distance the eye is *at* the origin looking down -Z.
	camera.yaw = 0;
	camera.pitch = 0;
	camera.derive_planes(100.0f);

	Matrix4f vp = camera.view_projection(WIDE);

	float[<4>] ahead = vp * (float[<4>]) { 0, 0, -10, 1 };
	test::@check(ahead[3] > 0.0f, "something ten units ahead is in front of the eye, w = %f", ahead[3]);
	test::@check(
		math::abs(ahead[0] / ahead[3]) < 0.01f && math::abs(ahead[1] / ahead[3]) < 0.01f,
		"and lands in the middle of the frame, at %f, %f", ahead[0] / ahead[3], ahead[1] / ahead[3]
	);

	float[<4>] behind = vp * (float[<4>]) { 0, 0, 10, 1 };
	test::@check(behind[3] < 0.0f, "and something ten units behind is behind, w = %f", behind[3]);
}

<*
 The planes do not collapse when the boom does.

 Both rules are multiples of `distance`, so at zero the old ones gave a near of
 0.0001 and a far of whatever `reach` happened to be — a depth ratio in the
 millions, which spends the buffer on the first centimetre and z-fights the rest
 of the scene. The failure is a picture that looks *nearly* right, which is why
 it is worth a check rather than a comment.
*>
fn void the_planes_do_not_collapse_when_the_boom_does() @test
{
	three::Camera camera = three::default_camera();
	camera.distance = 0;

	camera.derive_planes(400.0f);
	test::@check(camera.near_plane == three::FIRST_PERSON_NEAR, "the near plane is a statement about eyes, got %f", camera.near_plane);
	test::@check(camera.far_plane == 400.0f, "and the far plane is still the scene's reach, got %f", camera.far_plane);

	// An empty scene has not been walked yet and answers zero.
	camera.derive_planes(0.0f);
	test::@check(
		camera.far_plane > camera.near_plane,
		"a scene with no bounds is still projectable: %f to %f", camera.near_plane, camera.far_plane
	);
}

<*
 A rigid follow puts the orbit point on the thing, offset and all.
*>
fn void a_rigid_follow_lands_on_the_anchor() @test
{
	three::Camera camera = three::default_camera();
	three::CameraFollow follow = { .active = true, .offset = { 0, 1.5, 0 } };

	follow.apply(&camera, (Vec3) { 10, 2, -5 }, 16.0f);

	test::@check(camera.target.x == 10.0f, "x, got %f", camera.target.x);
	test::@check(camera.target.y == 3.5f, "y is the anchor plus the offset, got %f", camera.target.y);
	test::@check(camera.target.z == -5.0f, "z, got %f", camera.target.z);
}

<*
 A lagged follow is late by a time, not by a number of frames.

 The claim worth pinning: the same `lag_ms` has to leave the camera in the same
 place after the same *wall time*, whatever the frame rate — which is what an
 exponential buys and what a fixed fraction per frame does not. A camera tuned on
 a 60 Hz display would otherwise be twice as eager on a 144 Hz one, which reads
 as the lag setting not working rather than as the arithmetic being wrong.
*>
fn void a_lagged_follow_is_late_by_a_time_not_by_frames() @test
{
	Vec3 anchor = { 100, 0, 0 };

	three::Camera slow = three::default_camera();
	three::Camera fast = three::default_camera();
	slow.target = { 0, 0, 0 };
	fast.target = { 0, 0, 0 };

	three::CameraFollow follow = { .active = true, .lag_ms = 100.0f };

	// 96 ms of catching up, as six frames and as twelve.
	for (int i = 0; i < 6; i++) follow.apply(&slow, anchor, 16.0f);
	for (int i = 0; i < 12; i++) follow.apply(&fast, anchor, 8.0f);

	test::@check(slow.target.x > 5.0f, "the camera actually moved, got %f", slow.target.x);
	test::@check(slow.target.x < 95.0f, "and has not arrived, got %f", slow.target.x);
	test::@check(
		math::abs(slow.target.x - fast.target.x) < 0.5f,
		"both frame rates are in the same place after the same time: %f vs %f",
		slow.target.x, fast.target.x
	);
}

<*
 A frame that took a second does not teleport the camera.

 The same clamp `Controls` puts on its coast and for the same reason: a tool call
 that ran to completion on the frame loop hands the next tick a delta that is not
 a frame, and an unclamped exponential closes the whole gap for it — which reads
 as the camera cutting rather than as the frame having been slow.
*>
fn void a_long_frame_does_not_teleport_the_camera() @test
{
	three::Camera camera = three::default_camera();
	camera.target = { 0, 0, 0 };

	three::CameraFollow follow = { .active = true, .lag_ms = 100.0f };
	follow.apply(&camera, (Vec3) { 100, 0, 0 }, 5_000.0f);

	// 100 ms of a 100 ms time constant closes 1 - 1/e, about 63%.
	test::@check(
		camera.target.x < 70.0f,
		"five seconds of stall is spent as one clamped step, got %f", camera.target.x
	);
}

<*
 No time is no lag, because there is nothing for a lag to be a lag over.

 The first tick after an attach is the case: `follow_camera` is called with a
 zero delta so the camera starts on the thing rather than a frame behind it.
*>
fn void a_follow_with_no_elapsed_time_snaps() @test
{
	three::Camera camera = three::default_camera();
	camera.target = { 0, 0, 0 };

	three::CameraFollow follow = { .active = true, .lag_ms = 250.0f };
	follow.apply(&camera, (Vec3) { 7, 0, 0 }, 0);

	test::@check(camera.target.x == 7.0f, "snapped, got %f", camera.target.x);
}
