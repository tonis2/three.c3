<*
 `three.xr.left` and `three.xr.right`: the hand controllers' verbs. The display
 ones (`refreshRate`, `foveation`) are with the renderer's in `bind_scene.c3`.

 Hands are 0 (left) and 1 (right), buttons `HandButton` ordinals and spaces
 `HandSpace` ordinals; the prelude names them and checks them.
*>
module three;

import fastjs::js;
import std::math;
import std::math::vector;
import std::math::quaternion;

<*
 @return? js::THREW
*>
fn void? JsRuntime.bind_xr_verbs(&self, js::Value host)
{
	self.js.@bind(host, "xrHand", &js_xr_hand, self)!;
	self.js.@bind(host, "xrHandProfile", &js_xr_hand_profile, self)!;
	self.js.@bind(host, "xrHandPose", &js_xr_hand_pose, self)!;
	self.js.@bind(host, "xrHandMotion", &js_xr_hand_motion, self)!;
	self.js.@bind(host, "xrVibrate", &js_xr_vibrate, self)!;
	self.js.@bind(host, "xrHandHold", &js_xr_hand_hold, self)!;
	self.js.@bind(host, "xrHandTilt", &js_xr_hand_tilt, self)!;
	self.js.@bind(host, "xrHandPlace", &js_xr_hand_place, self)!;
	self.js.@bind(host, "xrHandConnect", &js_xr_hand_connect, self)!;
	self.js.@bind(host, "xrHandsReleaseAll", &js_xr_hands_release_all, self)!;
	self.js.@bind(host, "xrPresenting", &js_xr_presenting, self)!;
	self.js.@bind(host, "xrPassthroughGet", &js_xr_passthrough_get, self)!;
	self.js.@bind(host, "xrPassthroughSet", &js_xr_passthrough_set, self)!;
	self.js.@bind(host, "xrPassthroughSupported", &js_xr_passthrough_supported, self)!;
	self.js.@bind(host, "xrEmulateGet", &js_xr_emulate_get, self)!;
	self.js.@bind(host, "xrEmulateSet", &js_xr_emulate_set, self)!;
}

// What `xrHand` answers with.
struct HandView
{
	bool connected;
	float trigger;
	float squeeze;
	float stick_x;
	float stick_y;
	// `HandButton` bits.
	int down;
	int pressed;
	int released;
}

// What `xrHandPose` answers with, in the world.
struct HandPoseView
{
	Vec3 position;
	// XYZ Euler, as `Object3D.rotation` holds it.
	Vec3 rotation;
	// -Z after the rotation: where an aim pose points.
	Vec3 direction;
}

fn bool valid_hand(int hand) @local => hand == 0 || hand == 1;

// `xrHand(hand)` — this frame's state of one hand.
fn HandView js_xr_hand(JsRuntime* self, int hand)
{
	if (!valid_hand(hand)) return { };
	HandState* state = &self.hands.hand[hand];
	return {
		.connected = state.now.connected,
		.trigger = state.now.trigger,
		.squeeze = state.now.squeeze,
		.stick_x = state.now.stick.x,
		.stick_y = state.now.stick.y,
		.down = state.down,
		.pressed = state.pressed,
		.released = state.released,
	};
}

// `xrHandProfile(hand)` — which controller, such as "oculus/touch_controller"; empty when none.
fn String js_xr_hand_profile(JsRuntime* self, int hand)
{
	if (!valid_hand(hand)) return "";
	HandReading now = self.hands.hand[hand].now;
	return now.connected ? now.profile : "";
}

<*
 `xrHandPose(hand, space)` — a grip or aim pose in the world.

 Placed from the rig as it is now, so a script that moved the camera this frame
 reads the hand where it will be drawn.
*>
fn HandPoseView js_xr_hand_pose(JsRuntime* self, int hand, int space)
{
	if (!valid_hand(hand) || space < 0 || space >= HandSpace::len) return { };
	self.hands.to_world(self.pass.camera.target, self.pass.camera.yaw);
	HandPose pose = self.hands.hand[hand].world[space];
	return { .position = pose.position, .rotation = euler_from_quat(pose.rotation), .direction = pose.forward() };
}

<*
 `xrHandMotion(hand, space)` — how fast a grip or aim is moving, in the world:
 `{ linear, angular }`, metres and radians a second. Relative to where the player
 stands, so walking the rig does not add to it.
*>
fn HandMotion js_xr_hand_motion(JsRuntime* self, int hand, int space)
{
	if (!valid_hand(hand) || space < 0 || space >= HandSpace::len) return { };
	self.hands.to_world(self.pass.camera.target, self.pass.camera.yaw);
	return self.hands.hand[hand].world_motion[space];
}

<*
 `xrVibrate(hand, amplitude, seconds)` — a vibration for the headset to send.
 Amplitude 0 stops one; seconds 0 is the shortest pulse the controller makes.
*>
fn void? js_xr_vibrate(JsRuntime* self, int hand, float amplitude, float seconds)
{
	if (!valid_hand(hand)) return;
	if (!math::is_finite(amplitude) || !math::is_finite(seconds) || seconds < 0)
	{
		return self.js.fail("vibrate(amplitude, seconds) wants an amplitude from 0 to 1 and seconds of 0 or more")~;
	}
	Haptic* haptic = &self.hands.hand[hand].haptic;
	haptic.amplitude = math::clamp(amplitude, 0.0f, 1.0f);
	haptic.seconds = min(seconds, 10.0f);
	haptic.serial++;
}

<*
 `xrHandHold(hand, button, down, value)` — hold or let go of a button, for a
 script or a test with no controller. Trigger and squeeze take `value`.
*>
fn void js_xr_hand_hold(JsRuntime* self, int hand, int button, bool down, float value)
{
	if (!valid_hand(hand) || button < 0 || button >= HandButton::len) return;
	SyntheticHand* fake = &self.hands.synthetic[hand];
	fake.used = true;
	HandButton which = HandButton::from_ordinal(button);
	float pulled = down ? math::clamp(value, 0.0f, 1.0f) : 0;
	switch (which)
	{
		case TRIGGER: fake.trigger = pulled;
		case SQUEEZE: fake.squeeze = pulled;
		case A:
		case B:
		case X:
		case Y:
		case STICK:
		case MENU:
			if (down)
			{
				fake.buttons |= which.bit();
			}
			else
			{
				fake.buttons &= ~which.bit();
			}
	}
}

// `xrHandTilt(hand, x, y)` — hold the thumbstick over; +y is forward.
fn void js_xr_hand_tilt(JsRuntime* self, int hand, float x, float y)
{
	if (!valid_hand(hand)) return;
	SyntheticHand* fake = &self.hands.synthetic[hand];
	fake.used = true;
	fake.tilted = true;
	fake.stick = { math::clamp(x, -1.0f, 1.0f), math::clamp(y, -1.0f, 1.0f) };
}

<*
 `xrHandPlace(hand, position, direction)` — hold a hand at a place, pointing a
 way, both in tracking space: relative to where the rig stands and faces, as a
 real controller reports.
*>
fn void js_xr_hand_place(JsRuntime* self, int hand, Vec3 position, Vec3 direction)
{
	if (!valid_hand(hand)) return;
	SyntheticHand* fake = &self.hands.synthetic[hand];
	fake.used = true;
	fake.placed = true;
	HandPose pose = { .position = position, .rotation = facing(direction) };
	fake.pose = { pose, pose };
}

// `xrHandConnect(hand, on)` — a held-up hand with nothing pressed, or none at all.
fn void js_xr_hand_connect(JsRuntime* self, int hand, bool on)
{
	if (!valid_hand(hand)) return;
	self.hands.synthetic[hand] = on ? (SyntheticHand){ .used = true } : (SyntheticHand){ };
}

// `xrHandsReleaseAll()` — every synthetic hand let go of.
fn void js_xr_hands_release_all(JsRuntime* self) => self.hands.synthetic = { };

// `xrPresenting()` — whether frames are going to a headset right now.
fn bool js_xr_presenting(JsRuntime* self) => self.renderer != null && self.renderer.xr_display.presenting;

<*
 `xrPassthroughGet()` — whether the room shows behind the scene: asked for, and
 the headset can. False off a headset.
*>
fn bool js_xr_passthrough_get(JsRuntime* self)
{
	if (self.renderer == null) return false;
	XrDisplay* display = &self.renderer.xr_display;
	return display.passthrough_wanted && display.passthrough_supported;
}

<*
 `xrPassthroughSet(on)` — ask for the room, or the background back. Kept off a
 headset, like the other display requests, and dropped by a reload.
*>
fn void js_xr_passthrough_set(JsRuntime* self, bool on)
{
	if (self.renderer != null) self.renderer.xr_display.passthrough_wanted = on;
}

// `xrPassthroughSupported()` — whether this headset can show the room.
fn bool js_xr_passthrough_supported(JsRuntime* self) => self.renderer != null && self.renderer.xr_display.passthrough_supported;

<*
 `node.xrTrack(hand, space, shownWithHand)` — keep this top-level node on a hand
 from now on, hidden while the hand is away when `shownWithHand` is true.

 @return "False when the node is not top-level"
*>
fn bool js_xr_track(JsRuntime* self, NodeRef ref, int hand, int space, bool shown_with_hand)
{
	if (!valid_hand(hand) || space < 0 || space >= HandSpace::len) return false;
	return ref.scene.track_hand(ref.id, Hand::from_ordinal(hand), HandSpace::from_ordinal(space), shown_with_hand);
}

<*
 `node.xrUntrack()` — stop keeping this node on a hand.

 @return "False when it was not on one"
*>
fn bool js_xr_untrack(JsRuntime* self, NodeRef ref) => ref.scene.untrack_hand(ref.id);

// `xrEmulateGet()` — whether the mouse and keyboard are the hands.
fn bool js_xr_emulate_get(JsRuntime* self) => self.hands.emulate;

<*
 `xrEmulateSet(on)` — make the mouse and keyboard the hands, or give them back.
 The mouse stops turning the camera while it is a hand.
*>
fn void js_xr_emulate_set(JsRuntime* self, bool on)
{
	if (on == self.hands.emulate) return;
	self.hands.emulate = on;
	self.controls.enabled = !on;
}
