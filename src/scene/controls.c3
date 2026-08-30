<*
 A hand on the window, turned into camera movement.

 Left drag orbits, right or middle drag pans, the wheel zooms — Three.js's
 `OrbitControls` gestures against the turntable `camera.c3` already has. There is
 no new camera model: orbit *is* yaw, pitch and distance, which is why this file
 is short.

 Nothing here knows what a window is. `PointerState` is four numbers and two
 flags, filled in by `main.c3` from `c3w` and by the tests from nothing at all.
 That split is why any of this is testable — the whole suite runs headless.

 A script reaches the camera through `three.camera`, which writes the same
 fields; last writer wins, frame by frame, and neither side needs to know about
 the other. The exception is `enabled`, reached as `three.controls.enabled`,
 because last-writer-wins is not a scheme two things can share sixty times a
 second when one of them means to hold the camera *still*.
*>
module three;

import std::math;
import std::math::vector;

<*
 What the window has to say about the pointer this frame.

 `x` and `y` are in whatever units the platform reports the cursor in — points
 on macOS, pixels elsewhere — and `Controls` only ever takes differences, so the
 unit cancels. It matters in exactly one place: `viewport_height` has to be in
 the same unit, or a pan moves by the wrong amount on a retina display, which is
 why `main.c3` divides the surface extent by the window's backing scale.

 `y` grows upward. That is Cocoa's origin, and it is why orbit adds the vertical
 delta to pitch where a top-left convention would subtract it.
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
	// Whether the hand on the window reaches the camera at all.
	// 
	// A script that drives its own camera has to be able to say so. A follow
	// camera or a first-person look writes yaw, pitch and target every frame,
	// and the turntable writes them again from whatever the mouse did — two
	// things fighting over one matrix at sixty hertz, which reads as a camera
	// that shudders rather than as a control scheme that is wrong.
	// 
	// It takes the mouse away and nothing else: `three.camera.orbit()` still
	// moves the camera, because a script writing the camera on purpose was never
	// what this protects anything from.
	bool enabled;

	// Whether a button was down *last* frame, and where the cursor was when it
	// was. Together they are the entire state machine, and `dragging` is the
	// load-bearing half: without it the first frame of a drag applies the
	// distance from wherever the cursor was when the button was last released,
	// which on a wide window is most of a turn. The camera jumps once and then
	// tracks perfectly, so it reads as a one-off glitch rather than a missing
	// state bit.
	bool dragging;
	float last_x;
	float last_y;

	// Whether a frame with no button held has been seen yet. See `apply`.
	bool released;

	// How fast the orbit was going when the hand last moved, in degrees per
	// millisecond. Kept after the drag ends so the scene coasts to a stop
	// instead of stopping dead — see `apply`.
	float yaw_velocity;
	float pitch_velocity;

	float orbit_degrees_per_point;
	float zoom_per_scroll_point;
	// Distance may not reach zero: the eye would be inside the target, the view
	// matrix degenerates, and there is no scroll direction that gets back out.
	float min_distance;
	// The coast's time constant: the velocity falls to 1/e of itself every this
	// many milliseconds. Zero turns the coast off and the scene stops the moment
	// the button is released.
	float damping_ms;
}

const Controls DEFAULT_CONTROLS = { // On, and on is the only sane default: a window nobody can move the camera
// in is a bad way for a script to leave one, so the bad state has to be the
// one somebody asked for rather than the one they got by not asking.
	.enabled = true,
	.orbit_degrees_per_point = 0.4,
	.zoom_per_scroll_point = 0.01,
	.min_distance = 0.01, // Short. A hard flick is around 0.6 degrees per millisecond, and this buys
	// it another thirty-odd degrees over a third of a second — enough to read as
	// weight rather than as a camera that will not settle. Most drags end slowly
	// anyway, which is why the velocity is measured from the *last* frame of the
	// drag: a hand that decelerates before it lets go wants to stop there.
	.damping_ms = 60,
};


// The coast is integrated over a clamped step. A frame that took no time cannot
// say how fast anything was going, and one that took a second — a tool call ran
// to completion on the same loop — would fling the camera across the sky for a
// gesture that ended before it started.
const float MIN_SPIN_STEP_MS = 1.0;
const float MAX_SPIN_STEP_MS = 100.0;

// Below this the scene has stopped, whatever the arithmetic says. Two degrees a
// second is under a pixel a frame at any sane distance, and stopping there is
// what lets the window go back to sleep: an exponential never reaches zero, and
// a loop that idles only when the camera is still would never idle again.
const float MIN_SPIN_DEGREES_PER_MS = 0.002;

<*
 Folds one frame of pointer state into the camera.

 Called once per frame with whatever the window reported, whether or not
 anything happened — the no-op case is the common one and has to be cheap.

 Orbit wins when both buttons are down. Both gestures read the same delta, so
 applying both would move the camera twice for one hand movement; picking one is
 arbitrary but predictable, which is the property that matters.

 ## The coast

 An orbit that stopped the instant the button came up would be the one gesture
 here with no weight, and a turntable is exactly the thing people expect to keep
 turning. So the last frame's angular velocity is kept and decayed (see
 `damping_ms`), and `apply` keeps answering `true` until it runs out, which tells
 the loop it is not idle yet.

 The velocity is the last frame's, not the whole drag's average. A hand that
 slows before letting go is saying where it wants the scene to stop, and an
 average would throw it past that; a hand that stops dead sets it to zero, which
 is the same statement made more firmly.

 ## Disabled

 Every gesture is off, and the state a gesture leaves behind goes with them. The
 anchor would otherwise hold the cursor's position from before the script took
 the mouse — the one-frame jump `dragging` exists to prevent, arriving whenever
 the controls came back — and the spin would be a flick the scene had already
 stopped acknowledging. `released` is cleared because a button held across the
 moment the controls return is a button whose press this scheme never saw.

 It is cleared on every disabled frame rather than on the transition to one:
 detecting the edge would need a second bit remembering the last answer, and the
 whole state here is four fields that are already zero by the second frame.

 @param viewport_height : `Viewport height in the pointer's own units. Pan is skipped when it is not yet known.`
 @param dt_ms : `Milliseconds since the last call. Zero means the caller keeps no clock, and then there is no coast — which is every check that predates one.`
 @return `true when the camera moved, so an idle frame can be told from a moved one.`
*>
fn bool Controls.apply(&self, Camera* camera, PointerState pointer, float viewport_height, float dt_ms = 0)
{
	if (!self.enabled)
	{
		self.dragging = false;
		self.released = false;
		self.yaw_velocity = 0.0f;
		self.pitch_velocity = 0.0f;
		return false;
	}

	bool held = pointer.orbit || pointer.pan;

	// A held button is only believed once it has been seen released.
	// 
	// Mouse state arrives as a latch — a flag set by a down event and cleared by
	// the matching up — and the up does not always come. AppKit runs an event
	// loop of its own while a window is dragged by its title bar and swallows the
	// release, so the flag stays set for the rest of the session. Every later
	// mouse *movement* is then read as a drag with no button held, and the scene
	// turns on its own whenever the cursor crosses the window.
	// 
	// No headless test can find this: the fault is in what the window reports
	// rather than in what is done with it. Waiting for one button-free frame
	// costs nothing when the mouse is behaving — the loop renders hundreds
	// before anyone reaches the window — and makes a stuck latch heal at the
	// user's next real click rather than lasting until the process restarts.
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
	// cursor at all times works equally well, and was removed because it makes
	// the guard *unnecessary* rather than merely redundant: a second mechanism
	// hiding the failure of the first is a line no test can motivate.
	self.dragging = dragging;
	if (dragging)
	{
		self.last_x = pointer.x;
		self.last_y = pointer.y;
	}

	bool moved = false;

	if (dragging && pointer.orbit)
	{
		// Both signs are "the scene follows the hand": dragging right turns the
		// eye left, so the geometry appears to travel right with the cursor.
		// Getting either backwards is not a crash and not a warning — it is a
		// control scheme that feels wrong and cannot be argued with, so the
		// direction is asserted in `controls_test.c3`.
		float turn = -dx * self.orbit_degrees_per_point;
		float tilt =  dy * self.orbit_degrees_per_point;

		if (turn != 0.0f || tilt != 0.0f)
		{
			camera.yaw += turn;
			camera.pitch += tilt;
			camera.clamp_angles();
			moved = true;
		}

		// Recorded on every frame of the drag, zero included — including the
		// press frame, whose delta is deliberately zero. That is what makes a
		// hand stopping before it lets go stop the scene, and what makes grabbing
		// a coasting scene catch it.
		self.remember_spin(turn, tilt, dt_ms);
	}
	else if (dragging)
	{
		// A pan is a hand on the window too, so it catches the coast even though
		// it does not feed it.
		self.yaw_velocity = 0.0f;
		self.pitch_velocity = 0.0f;

		if (dx != 0.0f || dy != 0.0f)
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
	else if (self.coast(camera, dt_ms))
	{
		moved = true;
	}

	if (pointer.scroll != 0.0f)
	{
		// Exponential, not linear. A fixed step per notch is unusable at both
		// ends at once — either it crawls when the camera is far away or it slams
		// through the model when it is close — because what a person means by
		// "closer" is a fraction of where they are, not a number of metres.
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

<*
 Keeps how fast the orbit was going, for the coast to spend.

 Answering in degrees per millisecond rather than per frame is what makes the
 coast independent of the frame rate: the same flick throws the scene the same
 distance on a 60 Hz display and a 120 Hz one, which is not true of anything
 decaying by a fixed fraction per frame.

 `damping_ms` is not read here. How fast the hand was going is a fact and whether
 to spend it is a policy, and the policy has one owner — `coast`, below.
*>
fn void Controls.remember_spin(&self, float turn, float tilt, float dt_ms)
{
	// A frame that took no time cannot say how fast anything was going, and
	// there is nothing to divide by.
	if (dt_ms <= 0.0f)
	{
		self.yaw_velocity = 0.0f;
		self.pitch_velocity = 0.0f;
		return;
	}

	float step = math::clamp(dt_ms, MIN_SPIN_STEP_MS, MAX_SPIN_STEP_MS);
	self.yaw_velocity = turn / step;
	self.pitch_velocity = tilt / step;
}

<*
 Spends one frame of the coast, and decays what is left.

 @return `true while the scene is still turning, which is also "do not go idle yet".`
*>
fn bool Controls.coast(&self, Camera* camera, float dt_ms)
{
	// The one place `damping_ms` is read, and the one place a caller with no
	// clock is refused — the second because answering "yes, it moved" for a
	// frame that moved nothing would keep the window awake forever.
	if (self.damping_ms <= 0.0f || dt_ms <= 0.0f) return false;
	if (!self.spinning()) return false;

	float step = math::clamp(dt_ms, MIN_SPIN_STEP_MS, MAX_SPIN_STEP_MS);

	camera.yaw += self.yaw_velocity * step;
	camera.pitch += self.pitch_velocity * step;
	camera.clamp_angles();

	float decay = math::exp(-step / self.damping_ms);
	self.yaw_velocity *= decay;
	self.pitch_velocity *= decay;

	// Snapped rather than left to shrink forever: see MIN_SPIN_DEGREES_PER_MS.
	if (!self.spinning())
	{
		self.yaw_velocity = 0.0f;
		self.pitch_velocity = 0.0f;
	}

	return true;
}

fn bool Controls.spinning(&self)
{
	return math::abs(
		self.yaw_velocity
	) >= MIN_SPIN_DEGREES_PER_MS || math::abs(self.pitch_velocity) >= MIN_SPIN_DEGREES_PER_MS;
}