<*
 A hand on the window, turned into camera movement.

 Left drag orbits, right or middle drag pans, the wheel zooms — the gestures
 Three.js's `OrbitControls` uses, against the turntable `camera.c3` already has.
 There is no new camera model here and there is not meant to be: orbit *is*
 yaw, pitch and distance, which is why this file is short.

 **Nothing in here knows what a window is.** `PointerState` is four numbers and
 two flags, filled in by `main.c3` from `c3w` and by the tests from nothing at
 all. That split is the only reason any of this is testable: the whole suite
 runs headless, and a control scheme that could only be exercised by a person
 dragging a mouse would be verified by nobody, ever.

 **It is not a JS API.** A script reaches the camera through `three.camera`,
 which writes the same fields; last writer wins, frame by frame, and neither
 side needs to know about the other. Driving the camera *from* a script per
 frame is the next milestone — see `event_loop.md`.
*>
module three;

import std::math;
import std::math::vector;

<*
 What the window has to say about the pointer this frame.

 `x` and `y` are in whatever units the platform reports the cursor in — points
 on macOS, pixels elsewhere — and `Controls` only ever takes differences of
 them, so the unit cancels. It matters in exactly one place: `viewport_height`
 has to be in the same unit, or a pan moves by the wrong amount on a retina
 display. `main.c3` divides the surface extent by the window's backing scale
 for that reason.

 **`y` grows upward.** That is Cocoa's origin, not a choice, and it is why
 orbit adds the vertical delta to pitch where a top-left convention would
 subtract it.
*>
struct PointerState
{
	bool orbit;
	bool pan;
	float x;
	float y;
	// Accumulated over the last frame, positive away from the user. Zero on
	// platforms whose backend has no wheel support yet — see win32's stub.
	float scroll;
}

<*
 The drag anchor, and how fast each gesture moves the camera.

 The tuning is here rather than as constants so the defaults can be argued with
 in one place. They were chosen against a trackpad: a drag across the window
 turns the scene most of the way around, and a single wheel notch is a few
 percent of the distance.
*>
struct Controls
{
	// Whether a button was down *last* frame, and where the cursor was when it
	// was. Together they are the entire state machine, and `dragging` is the
	// load-bearing half: without it the first frame of a drag applies the
	// distance from wherever the cursor happened to be when the button was last
	// released, which on a wide window is most of a turn. The camera jumps once
	// and then tracks perfectly, so it reads as a one-off glitch rather than as
	// a missing state bit.
	bool dragging;
	float last_x;
	float last_y;

	// Whether a frame with no button held has been seen yet. See `apply`.
	bool released;

	float orbit_degrees_per_point;
	float zoom_per_scroll_point;
	// Distance may not reach zero: the eye would be inside the target, the view
	// matrix degenerates, and there is no scroll direction that gets back out.
	float min_distance;
}

fn Controls default_controls()
{
	return {
		.orbit_degrees_per_point = 0.4,
		.zoom_per_scroll_point = 0.01,
		.min_distance = 0.01,
	};
}

<*
 Fold one frame of pointer state into the camera.

 Called once per frame with whatever the window reported, whether or not
 anything happened — the no-op case is the common one and has to be cheap and
 silent.

 **Orbit wins when both buttons are down.** Both gestures read the same delta,
 so applying both would move the camera twice for one hand movement; picking
 one is arbitrary but predictable, which is the property that matters.

 @param viewport_height : `Viewport height in the pointer's own units. Pan is skipped when it is not yet known.`
 @return `true when the camera moved, so an idle frame can be told from a moved one.`
*>
fn bool Controls.apply(&self, Camera* camera, PointerState pointer, float viewport_height)
{
	bool held = pointer.orbit || pointer.pan;

	// **A held button is only believed once it has been seen released.**
	//
	// Mouse state arrives as a latch — a flag set by a down event and cleared by
	// the matching up — and the up does not always come. AppKit runs an event
	// loop of its own while a window is being dragged by its title bar and
	// swallows the release, so the flag stays set for the rest of the session.
	// Every later mouse *movement* is then read as a drag with no button held,
	// and the scene turns on its own whenever the cursor crosses the window.
	//
	// Measured, not theorised: it is what the very first windowed run of this
	// file did, and no headless test could have found it, because the fault is
	// in what the window reports rather than in what is done with it.
	//
	// Waiting for one button-free frame costs nothing when the mouse is behaving
	// — the loop renders hundreds of them before anyone reaches the window — and
	// makes a stuck latch heal at the user's next real click rather than lasting
	// until the process is restarted.
	if (!held) self.released = true;
	bool dragging = held && self.released;

	// Read the delta before the anchor is overwritten, and only when the drag
	// was already running last frame. See `Controls.dragging`.
	float dx = 0.0f;
	float dy = 0.0f;
	if (dragging && self.dragging)
	{
		dx = pointer.x - self.last_x;
		dy = pointer.y - self.last_y;
	}

	// The anchor is re-set on the press frame — the one frame the guard above
	// skips — and left alone while nothing is held. Keeping it current with the
	// cursor at all times would work equally well and was the first version of
	// this; it was removed because it makes the guard *unnecessary* rather than
	// merely redundant, and a second mechanism that hides the failure of the
	// first is a line no test can ever motivate.
	self.dragging = dragging;
	if (dragging)
	{
		self.last_x = pointer.x;
		self.last_y = pointer.y;
	}

	bool moved = false;

	if (dx != 0.0f || dy != 0.0f)
	{
		if (pointer.orbit)
		{
			// Both signs are "the scene follows the hand": dragging right turns
			// the eye left, so the geometry appears to travel right with the
			// cursor. Getting either backwards is not a crash and not a warning
			// — it is a control scheme that feels wrong and cannot be argued
			// with, so the direction is asserted in `controls_test.c3` rather
			// than left to whoever tries it next.
			camera.yaw -= dx * self.orbit_degrees_per_point;
			camera.pitch += dy * self.orbit_degrees_per_point;
			camera.clamp_angles();
			moved = true;
		}
		else
		{
			float per_point = camera.world_per_point(viewport_height);
			if (per_point > 0.0f)
			{
				Vec3 right;
				Vec3 up;
				camera.basis(&right, &up);
				camera.target -= right * (dx * per_point) + up * (dy * per_point);
				moved = true;
			}
		}
	}

	if (pointer.scroll != 0.0f)
	{
		// Exponential, not linear. A fixed step per notch is unusable at both
		// ends at once — either it crawls when the camera is far away or it
		// slams through the model when it is close — because what a person means
		// by "closer" is a fraction of where they are, not a number of metres.
		camera.distance = math::max(
			camera.distance * math::exp(-pointer.scroll * self.zoom_per_scroll_point),
			self.min_distance
		);
		moved = true;
	}

	// Once, at the end, rather than beside each gesture: two of the three change
	// the distance the planes are derived from, and a pan changes neither.
	if (moved) camera.derive_planes();

	return moved;
}
