<*
 The mouse, and what it does to the camera.

	`c3c test --trust=full --test-noleak --test-filter three_tests::controls`

 No GPU, no window and no scene: `Controls.apply` takes six numbers and moves a
 `Camera`, which is the whole reason `PointerState` exists as a struct instead
 of a `c3w::EventMap`. Everything here runs in microseconds.

 **Assert on where the picture went, not on the fields that moved it.** A sign
 flip in orbit or pan is not a crash, not a warning and not a validation
 message: it is a control scheme that feels wrong, which is a bug only a person
 dragging a mouse can normally find, and only once, and then they get used to
 it. So the checks project a fixed world point through the camera and say which
 way it travelled on screen — which is the claim a person is actually making
 when they say the controls are backwards.
*>
module three_tests::controls;

import three;
import std::core::test;
import std::math;
import std::math::vector;
import std::math::matrix;

// Pointer units, not pixels — the distinction `PointerState` documents. The
// aspect is deliberately not 1:1 so an x/y mix-up cannot cancel out.
const float VIEW_W = 800.0;
const float VIEW_H = 600.0;

fn bool close(float a, float b, float tolerance = 0.001) => math::abs(a - b) < tolerance;

<*
 A camera with every angle at zero, looking down -Z from five units away.

 Not `default_camera` — that one is turned 35 degrees for the look of it, and a
 test that starts from an oblique view has to do trigonometry to say what
 "moved right" means.
*>
fn three::Camera straight_on()
{
	return {
		.target = { 0, 0, 0 },
		.distance = 5.0,
		.yaw = 0.0,
		.pitch = 0.0,
		.fov = 45.0,
		.near_plane = 0.005,
		.far_plane = 40.0,
	};
}

<*
 Where a world point lands, in the pointer's own coordinates.

 Origin bottom-left and +Y up, matching `PointerState` — so a drag delta and
 the answer here are directly comparable, which is what
 `a_pan_tracks_the_cursor_point_for_point` needs.

 The projection's own +Y is already up: `gpu/target.c3` does the Vulkan flip
 with a negative viewport height rather than in the matrix, which
 `camera.c3` says in as many words.
*>
fn float[<2>] project(three::Camera* camera, Vec3 world)
{
	Matrix4f vp = camera.view_projection(VIEW_W / VIEW_H);
	float[<4>] clip = vp * (float[<4>]) { world.x, world.y, world.z, 1.0f };
	float ndc_x = clip[0] / clip[3];
	float ndc_y = clip[1] / clip[3];
	return { (ndc_x * 0.5f + 0.5f) * VIEW_W, (ndc_y * 0.5f + 0.5f) * VIEW_H };
}

fn bool orbit(three::Controls* controls, three::Camera* camera, float x, float y)
{
	return controls.apply(camera, { .orbit = true, .x = x, .y = y }, VIEW_H);
}

fn bool pan(three::Controls* controls, three::Camera* camera, float x, float y)
{
	return controls.apply(camera, { .pan = true, .x = x, .y = y }, VIEW_H);
}

fn bool hover(three::Controls* controls, three::Camera* camera, float x, float y)
{
	return controls.apply(camera, { .x = x, .y = y }, VIEW_H);
}

fn bool wheel(three::Controls* controls, three::Camera* camera, float scroll)
{
	return controls.apply(camera, { .x = 400, .y = 300, .scroll = scroll }, VIEW_H);
}

<*
 Drag right and the scene goes right; drag up and you get to see the top of it.

 The horizontal half is asserted on the screen, with a probe on the near side of
 the turntable — the part of the model a person believes they have hold of. The
 vertical half is asserted on the eye instead, because "up" is genuinely
 ambiguous on screen: lifting the camera pulls *everything* toward the horizon,
 so a near-side probe moves down while the view unmistakably moves up. The eye's
 height is the claim without the ambiguity.
*>
fn void the_scene_turns_with_the_hand() @test
{
	Vec3 probe = { 0, 0, 1 };

	three::Camera camera = straight_on();
	three::Controls controls = three::default_controls();

	float[<2>] before = project(&camera, probe);
	test::@check(close(before[0], VIEW_W * 0.5f, 0.5), "the probe did not start on the view axis");

	hover(&controls, &camera, 400, 300);
	orbit(&controls, &camera, 400, 300);
	orbit(&controls, &camera, 500, 300);

	float[<2>] after = project(&camera, probe);
	test::@check(
		after[0] > before[0] + 50.0f,
		"dragging right moved the near side of the scene from x=%f to x=%f — the controls are mirrored",
		before[0], after[0]
	);

	camera = straight_on();
	controls = three::default_controls();
	test::@check(close(camera.eye().y, 0.0, 0.001), "the eye did not start on the horizon");

	hover(&controls, &camera, 400, 300);
	orbit(&controls, &camera, 400, 300);
	orbit(&controls, &camera, 400, 400);

	test::@check(
		camera.eye().y > 1.0f,
		"dragging up put the eye at y=%f — it should rise, to look down on the scene",
		camera.eye().y
	);
}

<*
 The frame a button goes down on moves nothing.

 The bug this exists for: taking the delta against a stale anchor. The cursor
 was last sampled wherever the previous drag ended, so the first frame of the
 next one applies that whole distance at once — the camera snaps, then tracks
 the hand perfectly. It reads as a rendering hiccup rather than as a missing
 state bit, and it is invisible in any test that only ever drags once from the
 middle.
*>
fn void pressing_a_button_does_not_move_the_camera() @test
{
	three::Camera camera = straight_on();
	three::Controls controls = three::default_controls();

	hover(&controls, &camera, 780, 40);
	bool moved = orbit(&controls, &camera, 780, 40);

	test::@check(!moved, "the press frame reported movement");
	test::@check(close(camera.yaw, 0.0), "the press alone turned the camera to yaw %f", camera.yaw);
	test::@check(close(camera.pitch, 0.0), "the press alone tilted the camera to pitch %f", camera.pitch);
}

<*
 A button that is already down before the loop starts is not a drag, until it
 has been let go of once.

 **This is the one check here written from a live failure rather than from
 first principles.** The very first windowed run of `controls.c3` had the scene
 turning by itself with nobody touching the mouse: AppKit swallows the mouse-up
 that ends a title-bar drag, so `is_pressed(LEFT_MOUSE)` was latched on from
 before the window had even finished opening, and every stray cursor movement
 across the window orbited the camera.

 Nothing in a headless suite can see that — the fault is in what the window
 reports, not in what is done with it — but the *response* to it is ordinary
 logic and belongs under test, because it is a rule with no visible effect
 until the day it has one.

 The recovery half is the important half: a stuck latch has to heal at the next
 real click, or the controls would be dead for the rest of the session, which
 is a worse bug than the one being fixed.
*>
fn void a_button_already_down_is_not_a_drag_until_it_is_released() @test
{
	three::Camera camera = straight_on();
	three::Controls controls = three::default_controls();

	// Held from the first frame the loop ever ran, and moving.
	orbit(&controls, &camera, 100, 300);
	bool moved = orbit(&controls, &camera, 400, 300);

	test::@check(!moved, "a button held since startup was treated as a drag");
	test::@check(close(camera.yaw, 0.0), "the scene turned to yaw %f on its own", camera.yaw);

	// The user's next real click delivers the release that was missing.
	hover(&controls, &camera, 400, 300);
	orbit(&controls, &camera, 400, 300);
	moved = orbit(&controls, &camera, 500, 300);

	test::@check(moved, "the controls never came back after the latch cleared");
	test::@check(!close(camera.yaw, 0.0), "a real drag after the release turned nothing");
}

<*
 Moving the mouse with no button down is not a drag that resumes later.

 The second half of the anchor bug, and the half a single test misses: the
 anchor has to keep following the cursor while nothing is pressed, or the gap
 between one drag and the next is replayed into the camera the moment a button
 comes back down.
*>
fn void a_second_press_does_not_replay_the_gap() @test
{
	three::Camera camera = straight_on();
	three::Controls controls = three::default_controls();

	hover(&controls, &camera, 100, 300);
	orbit(&controls, &camera, 100, 300);
	orbit(&controls, &camera, 200, 300);
	float turned = camera.yaw;
	test::@check(!close(turned, 0.0), "the first drag turned nothing, so the rest of this proves nothing");

	// Button up, all the way across the window, then down again.
	hover(&controls, &camera, 200, 300);
	hover(&controls, &camera, 700, 300);
	bool moved = orbit(&controls, &camera, 700, 300);

	test::@check(!moved, "the re-press frame reported movement");
	test::@check(
		close(camera.yaw, turned),
		"the 500 points travelled with the button up reached the camera: yaw %f became %f",
		turned, camera.yaw
	);
}

<*
 However far up you drag, the eye stops one degree short of overhead.

 At exactly 90 the eye is on the up axis, `look_at`'s cross product is zero and
 every entry of the view matrix is NaN. Nothing raises, nothing logs: the frame
 comes back empty, and an empty frame is the single most expensive symptom in
 this project to attribute — see `plan.md` §7. So the matrix is checked, not
 just the angle.
*>
fn void the_eye_cannot_reach_the_pole() @test
{
	three::Camera camera = straight_on();
	three::Controls controls = three::default_controls();

	hover(&controls, &camera, 400, 300);
	orbit(&controls, &camera, 400, 300);
	orbit(&controls, &camera, 400, 100_300);

	test::@check(close(camera.pitch, 89.0), "pitch reached %f", camera.pitch);

	float[<16>] view = camera.view().m;
	for (usz i = 0; i < 16; i++)
	{
		test::@check(math::is_finite(view[i]), "the view matrix is not finite at %d: %f", i, view[i]);
	}

	orbit(&controls, &camera, 400, -100_300);
	test::@check(close(camera.pitch, -89.0), "pitch reached %f going the other way", camera.pitch);

	view = camera.view().m;
	for (usz i = 0; i < 16; i++)
	{
		test::@check(math::is_finite(view[i]), "the view matrix is not finite at %d under the floor", i);
	}
}

<*
 A pan moves the world under the cursor by exactly as many points as the cursor
 moved. Not approximately, and not "in the right direction".

 This is the one check that pins `Camera.world_per_point`'s field-of-view term.
 Drop it and pan still works, still feels smooth and is still in the right
 direction — it just drifts away from the cursor, by an amount that depends on
 the fov and the distance, which is exactly the kind of wrongness that gets
 tuned around with a magic constant instead of fixed.

 The probe is the *old* target, because the new one is useless here: panning
 moves the eye with the target, so the target projects to the middle of the
 screen before and after, whatever the maths did.
*>
fn void a_pan_tracks_the_cursor_point_for_point() @test
{
	Vec3 probe = { 0, 0, 0 };

	three::Camera camera = straight_on();
	three::Controls controls = three::default_controls();

	float[<2>] before = project(&camera, probe);

	hover(&controls, &camera, 400, 300);
	pan(&controls, &camera, 400, 300);
	pan(&controls, &camera, 500, 350);

	float[<2>] after = project(&camera, probe);

	test::@check(
		close(after[0] - before[0], 100.0, 0.5),
		"100 points of drag moved the scene %f points across",
		after[0] - before[0]
	);
	test::@check(
		close(after[1] - before[1], 50.0, 0.5),
		"50 points of drag moved the scene %f points up",
		after[1] - before[1]
	);
}

<*
 Zoom is proportional, and a notch out undoes a notch in.

 A fixed step per notch is unusable at both ends of the same scene: it crawls
 when the camera is far away and jumps through the model when it is close,
 because "closer" means a fraction of where you already are. The round trip is
 what distinguishes an exponential from a linear step that happens to look right
 at the distance it was tuned at.
*>
fn void zoom_is_a_fraction_of_where_the_eye_already_is() @test
{
	three::Camera camera = straight_on();
	three::Controls controls = three::default_controls();

	float started = camera.distance;

	wheel(&controls, &camera, 100);
	float near = camera.distance;
	test::@check(near < started, "scrolling away from the user did not move in: %f", near);

	wheel(&controls, &camera, -100);
	test::@check(
		close(camera.distance, started, 0.0001),
		"a notch out did not undo a notch in: %f became %f",
		started, camera.distance
	);

	// Twice as far away, the same notch has to cover twice the ground, or the
	// control is linear wearing an exponential's clothes.
	camera.distance = started * 2.0f;
	wheel(&controls, &camera, 100);
	test::@check(
		close(started * 2.0f - camera.distance, (started - near) * 2.0f, 0.001),
		"the same notch moved %f at twice the distance, not %f",
		started * 2.0f - camera.distance, (started - near) * 2.0f
	);
}

<*
 The eye cannot be scrolled into, or through, the thing it is looking at.

 Distance zero is a degenerate view matrix and there is no scroll direction that
 recovers from it — every further notch multiplies zero. The floor is the only
 thing between a slightly over-enthusiastic trackpad and a window that has to be
 restarted.
*>
fn void zoom_cannot_reach_the_target() @test
{
	three::Camera camera = straight_on();
	three::Controls controls = three::default_controls();

	wheel(&controls, &camera, 100_000);

	test::@check(camera.distance > 0.0f, "distance reached %f", camera.distance);
	test::@check(close(camera.distance, controls.min_distance), "distance stopped at %f", camera.distance);

	float[<16>] view = camera.view().m;
	for (usz i = 0; i < 16; i++)
	{
		test::@check(math::is_finite(view[i]), "the view matrix is not finite at %d after a hard zoom", i);
	}
}

<*
 A frame in which nothing happened changes nothing and says so.

 `apply` runs on every frame of a session that is mostly idle, so "no buttons,
 no scroll" is by far its most common input. A drift of a fraction of a degree
 per frame here is 60 a second and would be read as a bug in the scene.
*>
fn void an_idle_pointer_changes_nothing() @test
{
	three::Camera camera = straight_on();
	three::Camera untouched = camera;
	three::Controls controls = three::default_controls();

	for (uint i = 0; i < 120; i++)
	{
		bool moved = hover(&controls, &camera, 400 + (float)i, 300);
		test::@check(!moved, "an idle frame reported movement");
	}

	test::@check(close(camera.yaw, untouched.yaw), "yaw drifted to %f", camera.yaw);
	test::@check(close(camera.pitch, untouched.pitch), "pitch drifted to %f", camera.pitch);
	test::@check(close(camera.distance, untouched.distance), "distance drifted to %f", camera.distance);
	test::@check(
		close(camera.target.x, 0.0) && close(camera.target.y, 0.0) && close(camera.target.z, 0.0),
		"the target drifted to (%f, %f, %f)",
		camera.target.x, camera.target.y, camera.target.z
	);
}

<*
 A pan before the viewport size is known does nothing, rather than something
 infinite.

 A minimised window reports a zero extent, which is a division waiting to
 happen. An infinity in the target is not recoverable by dragging back: every
 subsequent frame projects NaN, so the window comes back from the dock empty and
 stays that way.
*>
fn void a_pan_with_no_viewport_yet_is_skipped() @test
{
	three::Camera camera = straight_on();
	three::Controls controls = three::default_controls();

	controls.apply(&camera, { .x = 400, .y = 300 }, 0.0);
	controls.apply(&camera, { .pan = true, .x = 400, .y = 300 }, 0.0);
	bool moved = controls.apply(&camera, { .pan = true, .x = 500, .y = 350 }, 0.0);

	test::@check(!moved, "a pan with no viewport reported movement");
	test::@check(
		math::is_finite(camera.target.x) && math::is_finite(camera.target.y),
		"the target became (%f, %f, %f)",
		camera.target.x, camera.target.y, camera.target.z
	);
	test::@check(close(camera.target.x, 0.0) && close(camera.target.y, 0.0), "the target moved anyway");
}

<*
 The near and far planes follow the distance, whoever changed it.

 They are derived and never set — a fixed near plane against a model a kilometre
 wide spends the whole depth buffer on the first few metres. A drag that moved
 the camera without re-deriving them would z-fight after a zoom and not before,
 which is a bug that only appears once somebody has been using the thing for a
 while.
*>
fn void the_planes_follow_the_distance() @test
{
	three::Camera camera = straight_on();
	three::Controls controls = three::default_controls();

	wheel(&controls, &camera, -400);

	test::@check(camera.distance > 5.0f, "the zoom did not move out: %f", camera.distance);
	test::@check(
		close(camera.near_plane, math::max(camera.distance * 0.001f, 0.0001f), 0.00001),
		"near is %f at distance %f",
		camera.near_plane, camera.distance
	);
	test::@check(
		close(camera.far_plane, camera.distance * 8.0f, 0.001),
		"far is %f at distance %f",
		camera.far_plane, camera.distance
	);
}

<*
 Yaw stays in [-180, 180) however long the session runs, and wrapping it does
 not move the picture.

 Yaw only ever accumulates — one drag delta at a time, with nothing to reset it
 — so an afternoon of turning walks it into the thousands, where a float's
 spacing is coarse enough that a slow drag starts to step visibly. The second
 assertion is the one that matters: a wrap that changed the view would be a
 worse bug than the drift it fixed.
*>
fn void yaw_does_not_wander_off() @test
{
	three::Camera camera = straight_on();
	three::Controls controls = three::default_controls();

	hover(&controls, &camera, 0, 300);
	orbit(&controls, &camera, 0, 300);
	for (uint i = 1; i <= 20; i++)
	{
		orbit(&controls, &camera, (float)i * 100.0f, 300);
	}

	// 2000 points at 0.4 degrees each, turning the other way: -800, which is
	// -80 once the turns are taken off.
	test::@check(math::abs(camera.yaw) <= 180.0f, "yaw ran to %f", camera.yaw);
	test::@check(close(camera.yaw, -80.0, 0.01), "yaw wrapped to %f, expected -80", camera.yaw);

	three::Camera unwrapped = straight_on();
	unwrapped.yaw = -800.0;
	Vec3 wrapped_eye = camera.eye();
	Vec3 direct_eye = unwrapped.eye();
	test::@check(
		close(wrapped_eye.x, direct_eye.x, 0.001) && close(wrapped_eye.z, direct_eye.z, 0.001),
		"wrapping moved the eye: (%f, %f) against (%f, %f)",
		wrapped_eye.x, wrapped_eye.z, direct_eye.x, direct_eye.z
	);
}
