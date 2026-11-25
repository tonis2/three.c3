<*
 `--quest`'s target size: a Quest 3 eye's pixels per unit of view tangent, over
 whatever field of view the desktop camera has.
*>
module three_tests::headset;

import three;
import std::math;

<*
 The headset's own field of view takes the headset's own rows: 0.7 of 1760 over
 the eye's 44 degrees up and 55 down, which is what `xr: swapchain` reports it
 renders at that scale (1176x1232). Narrower views take proportionally fewer, by
 the tangent and not the angle.
*>
fn void the_eyes_density_gives_the_eyes_rows() @test
{
	float density = 0.7f * three::QUEST3_EYE_ROWS / three::QUEST3_EYE_TAN_SPAN;
	// The eye's span as a symmetric view: the same tangents, split evenly.
	float eye_fov = 2.0f * (float)math::rad_to_deg(math::atan(three::QUEST3_EYE_TAN_SPAN * 0.5));

	uint eye = three::headset_rows(density, eye_fov);
	test::@check(eye >= 1231 && eye <= 1233, "the eye's view takes its 1232 rows, got %d", eye);
	// A 45 degree camera spans tan 22.5 either side: 0.8284 of a unit against 2.3938.
	uint desk = three::headset_rows(density, 45.0f);
	test::@check(desk >= 426 && desk <= 427, "a 45 degree camera takes 427 rows, got %d", desk);
}

<*
 The rows stay inside what a target can be: at least one, and no more than
 `RENDER_MAX_SIDE` however wide the view or dense the eye.
*>
fn void the_rows_stay_inside_a_target() @test
{
	test::@check(three::headset_rows(0.001f, 1.0f) == 1, "a sliver of a view is one row");
	test::@check(
		three::headset_rows(100000.0f, 170.0f) == (uint)three::RENDER_MAX_SIDE,
		"and a huge one stops at the largest side"
	);
}
