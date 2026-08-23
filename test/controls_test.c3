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
import c3w;
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
	three::Controls controls = three::DEFAULT_CONTROLS;

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
	controls = three::DEFAULT_CONTROLS;
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
	three::Controls controls = three::DEFAULT_CONTROLS;

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
	three::Controls controls = three::DEFAULT_CONTROLS;

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
	three::Controls controls = three::DEFAULT_CONTROLS;

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
	three::Controls controls = three::DEFAULT_CONTROLS;

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
	three::Controls controls = three::DEFAULT_CONTROLS;

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
	three::Controls controls = three::DEFAULT_CONTROLS;

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
	three::Controls controls = three::DEFAULT_CONTROLS;

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
	three::Controls controls = three::DEFAULT_CONTROLS;

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
	three::Controls controls = three::DEFAULT_CONTROLS;

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
	three::Controls controls = three::DEFAULT_CONTROLS;

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
	three::Controls controls = three::DEFAULT_CONTROLS;

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

// ============================================================================
// The coast
// ============================================================================

// A drag frame that says how long it took, which the helpers above deliberately
// do not: every check that predates the coast passes dt = 0 and therefore never
// reaches any of it.
fn bool orbit_over(three::Controls* controls, three::Camera* camera, float x, float y, float dt_ms)
{
	return controls.apply(camera, { .orbit = true, .x = x, .y = y }, VIEW_H, dt_ms);
}

fn bool idle_for(three::Controls* controls, three::Camera* camera, float dt_ms)
{
	return controls.apply(camera, { .x = 400, .y = 300 }, VIEW_H, dt_ms);
}

// Press, drag, and let go — the shortest gesture that leaves the scene turning.
fn void flick(three::Controls* controls, three::Camera* camera, float by = 60.0f, float dt_ms = 16.0f)
{
	idle_for(controls, camera, dt_ms);
	orbit_over(controls, camera, 400, 300, dt_ms);
	orbit_over(controls, camera, 400 + by * 0.5f, 300, dt_ms);
	orbit_over(controls, camera, 400 + by, 300, dt_ms);
}

<*
 The scene keeps turning after the hand lets go, in the direction it was going.

 A turntable that stopped dead on release would be the one gesture here with no
 weight at all. The direction matters as much as the fact: a coast that ran
 backwards would still "damp", and it would be unmistakably wrong to use and
 perfectly plausible in a diff.
*>
fn void a_flick_keeps_turning_after_the_hand_lets_go() @test
{
	three::Camera camera = three::default_camera();
	three::Controls controls = three::DEFAULT_CONTROLS;

	flick(&controls, &camera);
	float at_release = camera.yaw;

	test::@check(idle_for(&controls, &camera, 16), "the frame after the release still moves the camera");
	float after = camera.yaw;

	// The drag was to the right, which turns the eye left: yaw falls.
	test::@check(after < at_release, "and the coast carries on turning left, %f -> %f", at_release, after);
}

<*
 It slows down, and it stops.

 Both halves are load-bearing and only the first is obvious. An exponential
 never reaches zero, so without the floor the camera would keep creeping by
 amounts nobody can see — and `apply` would keep answering "moved", which is the
 sentence `main.c3` reads as "do not go to sleep". The window would then never
 idle again, for a gesture that ended a minute ago.
*>
fn void the_coast_slows_down_and_stops() @test
{
	three::Camera camera = three::default_camera();
	three::Controls controls = three::DEFAULT_CONTROLS;

	flick(&controls, &camera);

	int frames = 0;
	while (idle_for(&controls, &camera, 16))
	{
		frames++;
		if (frames > 200) break;
	}
	test::@check(frames <= 200, "the coast is not endless");

	test::@check(frames > 1, "it took more than one frame to stop, got %d", frames);
	test::@check(frames < 60, "and stopped inside a second at 60Hz, got %d frames", frames);
	test::@check(
		!idle_for(&controls, &camera, 16),
		"and once stopped it stays stopped, which is what lets the window sleep"
	);
}

<*
 Each frame of the coast moves the camera less than the one before it.
*>
fn void the_coast_decays() @test
{
	three::Camera camera = three::default_camera();
	three::Controls controls = three::DEFAULT_CONTROLS;

	flick(&controls, &camera);

	float previous_step = float::max;
	for (int i = 0; i < 5; i++)
	{
		float before = camera.yaw;
		test::@check(idle_for(&controls, &camera, 16), "still coasting at frame %d", i);
		float step = math::abs(camera.yaw - before);
		test::@check(step < previous_step, "frame %d moved less than the one before: %f < %f", i, step, previous_step);
		previous_step = step;
	}
}

<*
 A hand that stops before it lets go means the scene stops too.

 The velocity is the last frame's rather than the drag's average for exactly
 this: someone who lines a view up, pauses on it, and releases is saying where
 they want it, and an average would throw it past that every time.
*>
fn void a_hand_that_stops_before_it_lets_go_does_not_throw_the_scene() @test
{
	three::Camera camera = three::default_camera();
	three::Controls controls = three::DEFAULT_CONTROLS;

	flick(&controls, &camera);
	// Still held, and now still.
	orbit_over(&controls, &camera, 460, 300, 16);
	float settled = camera.yaw;

	test::@check(!idle_for(&controls, &camera, 16), "the release after a pause coasts nowhere");
	test::@check(camera.yaw == settled, "and the camera is where it was left, %f", camera.yaw);
}

<*
 Grabbing a coasting scene catches it, which is how a person stops one.
*>
fn void grabbing_a_coasting_scene_stops_it() @test
{
	three::Camera camera = three::default_camera();
	three::Controls controls = three::DEFAULT_CONTROLS;

	flick(&controls, &camera);
	idle_for(&controls, &camera, 16);

	// The press frame: a button goes down and the anchor is set, so its own
	// delta is zero by construction.
	orbit_over(&controls, &camera, 200, 200, 16);
	float caught = camera.yaw;
	orbit_over(&controls, &camera, 200, 200, 16);

	test::@check(camera.yaw == caught, "holding still holds it still, %f", camera.yaw);
	test::@check(!idle_for(&controls, &camera, 16), "and letting go of a still hand starts nothing");
}

<*
 A pan catches it too. It does not feed the coast — panning is not turning — but
 a hand on the window is a hand on the window.
*>
fn void a_pan_catches_the_coast_as_well() @test
{
	three::Camera camera = three::default_camera();
	three::Controls controls = three::DEFAULT_CONTROLS;

	flick(&controls, &camera);
	controls.apply(&camera, { .pan = true, .x = 400, .y = 300 }, VIEW_H, 16);
	float caught = camera.yaw;

	controls.apply(&camera, { .pan = true, .x = 420, .y = 300 }, VIEW_H, 16);
	test::@check(camera.yaw == caught, "the pan moved the target and not the angle, %f", camera.yaw);
	test::@check(!idle_for(&controls, &camera, 16), "and the coast is gone");
}

<*
 Damping off means the scene stops dead, which is what the field is for.
*>
fn void damping_off_stops_the_scene_dead() @test
{
	three::Camera camera = three::default_camera();
	three::Controls controls = three::DEFAULT_CONTROLS;
	controls.damping_ms = 0;

	flick(&controls, &camera);
	float at_release = camera.yaw;

	test::@check(!idle_for(&controls, &camera, 16), "nothing to spend");
	test::@check(camera.yaw == at_release, "and the camera has not moved, %f", camera.yaw);
}

<*
 A caller with no clock gets no coast — which is what protects every check
 written before there was one.
*>
fn void a_caller_with_no_clock_never_coasts() @test
{
	three::Camera camera = three::default_camera();
	three::Controls controls = three::DEFAULT_CONTROLS;

	hover(&controls, &camera, 400, 300);
	orbit(&controls, &camera, 400, 300);
	orbit(&controls, &camera, 460, 300);
	float at_release = camera.yaw;

	test::@check(!hover(&controls, &camera, 460, 300), "no dt, no velocity, no coast");
	test::@check(camera.yaw == at_release, "the camera stopped where the drag did, %f", camera.yaw);
}

<*
 A frame that took a second does not fling the camera across the sky.

 The loop that drives this is the same one that answers tool calls, so a script
 that runs for two seconds arrives here as a single enormous frame. Both ends of
 the step are clamped for it: without the ceiling one slow frame would multiply
 the last flick by sixty, and without the floor a frame timed at zero would
 divide by it.
*>
fn void a_very_long_frame_does_not_fling_the_camera() @test
{
	three::Camera camera = three::default_camera();
	three::Controls controls = three::DEFAULT_CONTROLS;

	flick(&controls, &camera);
	float at_release = camera.yaw;

	idle_for(&controls, &camera, 5_000);
	float travelled = math::abs(camera.yaw - at_release);

	test::@check(travelled > 0.0f, "it still coasted, %f", travelled);
	test::@check(travelled < 90.0f, "but not across the sky, %f degrees in one frame", travelled);
}

// ============================================================================
// The cursor
// ============================================================================

<*
 An open hand over the scene, a closed one while dragging, and the arrow
 everywhere else.

 Three lines, checked because their call site is `main.c3` and the claim they
 make — that a pan closes the hand as well as an orbit — is the kind that is
 true when written and quietly false a milestone later.
*>
fn void the_cursor_says_what_the_hand_is_doing() @test
{
	test::@check(three::cursor_shape(inside: true, dragging: false) == OPEN_HAND, "over the scene");
	test::@check(three::cursor_shape(inside: true, dragging: true) == CLOSED_HAND, "and holding it");
	test::@check(three::cursor_shape(inside: false, dragging: false) == ARROW, "off the scene");
	test::@check(
		three::cursor_shape(inside: false, dragging: true) == CLOSED_HAND,
		"a drag that leaves the window is still a drag"
	);
}

<*
 And it says whether there is anything to click.

 The one state that carries information the person cannot get any other way:
 `onClick` picks, and nothing else on screen says whether there is anything
 under the pointer to be picked. It is also the one that has to lose — a drag is
 a drag whatever it started over.
*>
fn void the_cursor_points_at_what_can_be_clicked() @test
{
	test::@check(
		three::cursor_shape(inside: true, dragging: false, over: true) == POINTING_HAND,
		"over something"
	);
	test::@check(
		three::cursor_shape(inside: true, dragging: false, over: false) == OPEN_HAND,
		"over nothing"
	);
	test::@check(
		three::cursor_shape(inside: true, dragging: true, over: true) == CLOSED_HAND,
		"and a drag beats it, wherever it began"
	);
	test::@check(
		three::cursor_shape(inside: false, dragging: false, over: true) == ARROW,
		"as does being off the image, which nothing can be over"
	);
}

<*
 The picker is asked once per place the pointer stops, not once per frame.

 The broad phase is one world-AABB test per instance, so on the thousand-cube
 scene this project exists to make a point about, a raycast per frame is a
 thousand tests to choose between two pictures of a hand. A still cursor must
 cost nothing.
*>
fn void a_still_pointer_does_not_ask_the_picker_again() @test
{
	three::Hover hover;
	three::Cursor at = { .inside = true, .x = 100, .y = 100 };

	test::@check(hover.stale(at), "the first time, because nothing is known yet");
	hover.keep(at, true);

	test::@check(!hover.stale(at), "and not again while the pointer has not moved");
	test::@check(hover.over, "with the answer kept");

	three::Cursor moved = { .inside = true, .x = 101, .y = 100 };
	test::@check(hover.stale(moved), "one pixel is a move");
}

<*
 Coming back asks again, because the camera moved while the hand was away.

 A drag is the ordinary reason the answer stops being wanted, and a drag turns
 the camera by definition — so what was under the pointer before it started is
 no evidence at all about what is under it now, even if the pointer came back to
 the same pixel.
*>
fn void leaving_and_returning_asks_the_picker_again() @test
{
	three::Hover hover;
	three::Cursor at = { .inside = true, .x = 100, .y = 100 };

	hover.keep(at, true);
	hover.forget();

	test::@check(hover.stale(at), "the same pixel is a new question after a drag");
	test::@check(!hover.over, "and nothing is claimed in the meantime");
}

// ============================================================================
// The controls a script can turn off (plan.md §17)
// ============================================================================

<*
 On by default, and that is the load-bearing half of the decision.

 A window nobody can move the camera in is a bad state to leave one in, so it
 has to be a state somebody asked for rather than one they arrived at by not
 asking. `plan.md` §9 spent four milestones undecided on whether this flag should
 exist at all; what settled it is that the camera work in §17 cannot be designed
 around a control scheme that might or might not be writing the same fields.
*>
fn void the_hand_reaches_the_camera_until_a_script_says_otherwise() @test
{
	test::@check(three::DEFAULT_CONTROLS.enabled, "the mouse starts connected");
}

<*
 Disabled, no gesture reaches the camera and none of them claims to have.

 The return value matters as much as the camera does: it is what tells the loop
 whether the window may go back to sleep, so a disabled scheme reporting `true`
 would keep a window awake for a hand it is ignoring.
*>
fn void a_disabled_control_scheme_moves_nothing() @test
{
	three::Camera camera = three::default_camera();
	three::Camera before = camera;
	three::Controls controls = three::DEFAULT_CONTROLS;
	controls.enabled = false;

	test::@check(!hover(&controls, &camera, 400, 300), "a hover moves nothing, as it never did");
	test::@check(!orbit(&controls, &camera, 400, 300), "the press frame of an orbit moves nothing");
	test::@check(!orbit(&controls, &camera, 460, 300), "and neither does the drag frame after it");
	test::@check(!pan(&controls, &camera, 500, 340), "a pan moves nothing");
	test::@check(!wheel(&controls, &camera, 3.0f), "and the wheel does not zoom");

	test::@check(camera.yaw == before.yaw, "yaw is where it was, %f -> %f", before.yaw, camera.yaw);
	test::@check(camera.pitch == before.pitch, "pitch is where it was, %f -> %f", before.pitch, camera.pitch);
	test::@check(
		camera.distance == before.distance,
		"distance is where it was, %f -> %f", before.distance, camera.distance
	);
	test::@check(
		camera.target.x == before.target.x && camera.target.y == before.target.y
			&& camera.target.z == before.target.z,
		"and the pan did not move the target"
	);
}

<*
 A script taking the mouse mid-drag does not leave the camera a jump to make.

 The anchor is the whole reason this check exists. Dropping the gesture without
 dropping `last_x` would leave the position the cursor had *before* the script
 took over, and the hand goes on travelling in the meantime — so the frame the
 controls came back on would apply the entire distance at once. That is the
 one-frame lurch `Controls.dragging` was introduced to prevent, arriving through
 a door that did not exist when it was written.

 A button still held when the controls return has to be let go of first, for the
 reason the stuck-latch guard gives: this scheme never saw the press.
*>
fn void taking_the_mouse_mid_drag_drops_the_anchor() @test
{
	three::Camera camera = three::default_camera();
	three::Controls controls = three::DEFAULT_CONTROLS;

	hover(&controls, &camera, 400, 300);
	orbit(&controls, &camera, 400, 300);
	test::@check(orbit(&controls, &camera, 440, 300), "the drag was moving the camera");
	float turned = camera.yaw;

	// The hand keeps going while the script has the mouse.
	controls.enabled = false;
	orbit(&controls, &camera, 700, 300);
	controls.enabled = true;

	test::@check(
		!orbit(&controls, &camera, 900, 300),
		"a button held across the gap is not a drag this scheme ever saw begin"
	);
	test::@check(
		camera.yaw == turned,
		"and the camera did not jump by where the hand went, %f -> %f", turned, camera.yaw
	);

	// Let go, press again, and it is an ordinary drag from here.
	hover(&controls, &camera, 900, 300);
	orbit(&controls, &camera, 900, 300);
	test::@check(orbit(&controls, &camera, 940, 300), "a fresh press drags again");
}

<*
 The coast is spent, not parked, so coming back does not resume an old flick.

 A velocity kept across a disabled stretch would restart the scene turning at
 whatever speed the hand left it at — after a mode that lasted a minute, from a
 gesture nobody remembers making.
*>
fn void taking_the_mouse_stops_the_coast() @test
{
	three::Camera camera = three::default_camera();
	three::Controls controls = three::DEFAULT_CONTROLS;

	flick(&controls, &camera);
	test::@check(controls.spinning(), "the flick left the scene turning");
	float at_release = camera.yaw;

	controls.enabled = false;
	test::@check(!idle_for(&controls, &camera, 16), "a disabled frame is not a moving one");
	test::@check(!controls.spinning(), "and the spin is gone rather than held");
	test::@check(
		camera.yaw == at_release,
		"the scene stopped where the hand left it, %f -> %f", at_release, camera.yaw
	);

	controls.enabled = true;
	test::@check(!idle_for(&controls, &camera, 16), "coming back resumes nothing");
	test::@check(camera.yaw == at_release, "and the camera is still where it stopped");
}
