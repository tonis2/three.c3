<*
 The two hand controllers, as scripts see them: buttons with press and release
 edges, trigger and squeeze, the thumbstick, the grip and aim poses, and a
 vibration request.

 Shared code. The headset fills a `HandsReading` from OpenXR (`src/xr/input.c3`);
 the desktop's emulation and the tests fill one by hand. Everything after the
 reading is the same in all three.

 Poses arrive in tracking space and are placed in the world through the rig:
 `camera.target` is where the player stands and `camera.yaw` where they face,
 the same rig the head is placed with.
*>
module three;

import std::math;
import std::math::vector;
import std::math::quaternion;
import std::collections::list;
import c3w;
import collision;

enum Hand : char
{
	LEFT,
	RIGHT,
}

// The bit each sets in `HandReading.buttons` is `1 << ordinal`.
enum HandButton : char
{
	A,
	B,
	X,
	Y,
	STICK,
	MENU,
	TRIGGER,
	SQUEEZE,
}

enum HandSpace : char
{
	// Where the hand holds things: an object held is a child of this.
	GRIP,
	// Where the controller points: -Z out of the front of it.
	AIM,
}

// A trigger or squeeze counts as held from here...
const float HAND_PULL_DOWN = 0.6f;
// ...until it falls to here, so a finger resting at the threshold does not chatter.
const float HAND_PULL_UP = 0.4f;

// Every button that is a click, not a pull.
const char HAND_CLICK_BITS = 0b0011_1111;

// How long a hand's motion is averaged over when it is worked out from its poses,
// in seconds. One frame's step at 120 Hz is mostly tracking noise.
const float HAND_MOTION_SMOOTHING = 0.05f;

struct HandPose
{
	Vec3 position;
	Quaternionf rotation;
}

<*
 How fast a hand space moves: metres a second, and radians a second about the
 axis it turns around.
*>
struct HandMotion
{
	Vec3 linear;
	Vec3 angular;
}

<*
 One hand on one frame, in tracking space.
*>
struct HandReading
{
	bool connected;
	// By `HandSpace`.
	HandPose[2] pose;
	// By `HandSpace`, when the runtime measured it; see `measured`.
	HandMotion[2] motion;
	// Whether `motion` came with the reading. A hand without it, synthetic or
	// emulated, has its motion worked out from its poses frame to frame.
	bool measured;
	float trigger;
	float squeeze;
	// +y is the stick pushed forward.
	float[<2>] stick;
	// The click buttons only; trigger and squeeze come from their values.
	char buttons;
	// Which controller, such as "oculus/touch_controller". Borrowed; empty when unknown.
	String profile;
}

struct HandsReading
{
	// By `Hand`.
	HandReading[2] hand;
	// Between the eyes, in tracking space, when `head_tracked`.
	HandPose head;
	bool head_tracked;
}

<*
 A vibration a script asked for. The host sends it when `serial` moves.
*>
struct Haptic
{
	float amplitude;
	// Zero or less is the shortest pulse the controller makes.
	float seconds;
	uint serial;
}

struct HandState
{
	HandReading now;
	char down;
	char pressed;
	char released;
	// By `HandSpace`, placed by `Hands.to_world`.
	HandPose[2] world;
	// By `HandSpace`, in tracking space: the reading's, or worked out from its
	// poses. Turned into the world by `Hands.to_world`.
	HandMotion[2] motion;
	// By `HandSpace`, `motion` turned into the world.
	HandMotion[2] world_motion;
	Haptic haptic;
}

<*
 What a script is holding through `three.xr.right.press` and its siblings,
 merged into every reading the way `SyntheticKeys` is merged into the keyboard.
 Any of it connects the hand, so a test needs no headset.
*>
struct SyntheticHand
{
	bool used;
	char buttons;
	float trigger;
	float squeeze;
	float[<2>] stick;
	bool tilted;
	bool placed;
	// By `HandSpace`, in tracking space.
	HandPose[2] pose;
}

struct Hands
{
	// By `Hand`.
	HandState[2] hand;
	SyntheticHand[2] synthetic;
	// Mouse and keys drive the hands on a desktop run.
	bool emulate;
	// The last head pose read, in tracking space, kept while the head is not tracked.
	HandPose head;
	bool head_tracked;
	// `head`, placed by `Hands.to_world`.
	HandPose head_world;
}

fn char HandButton.bit(self) => (char)(1 << self.ordinal);

fn HandReading SyntheticHand.merge(&self, HandReading real)
{
	if (!self.used) return real;
	HandReading out = real;
	out.connected = true;
	out.buttons |= self.buttons;
	out.trigger = max(out.trigger, self.trigger);
	out.squeeze = max(out.squeeze, self.squeeze);
	if (self.tilted) out.stick = self.stick;
	if (self.placed) out.pose = self.pose;
	if (out.profile.len == 0) out.profile = "synthetic";
	return out;
}

<*
 Takes one frame's reading: the synthetic hands folded in, then the edges and
 the motion. A hand that disconnects lets go of everything it held.

 @param dt : "Wall seconds since the last reading; 0 works out no motion"
*>
fn void Hands.step(&self, HandsReading reading, float dt = 0)
{
	self.head_tracked = reading.head_tracked;
	if (reading.head_tracked) self.head = reading.head;
	foreach (i, &state : self.hand)
	{
		HandReading now = self.synthetic[i].merge(reading.hand[i]);
		state.track_motion(now, dt);
		char before = state.down;
		char down = 0;
		if (now.connected)
		{
			down = now.buttons & HAND_CLICK_BITS;
			down |= pulled(before, HandButton.TRIGGER, now.trigger);
			down |= pulled(before, HandButton.SQUEEZE, now.squeeze);
		}
		state.now = now;
		state.down = down;
		state.pressed = down & ~before;
		state.released = before & ~down;
	}
}

<*
 The hand's motion this frame: what the runtime measured, or else the change from
 the last reading's poses, averaged over `HAND_MOTION_SMOOTHING`. Called before
 `now` replaces the last reading.
*>
fn void HandState.track_motion(&self, HandReading now, float dt)
{
	if (!now.connected)
	{
		self.motion = { };
		return;
	}
	if (now.measured)
	{
		self.motion = now.motion;
		return;
	}
	// A hand just arrived has nothing to differ from.
	if (!self.now.connected || dt <= 0)
	{
		self.motion = { };
		return;
	}
	float k = min(1.0f, dt / HAND_MOTION_SMOOTHING);
	foreach (s, &motion : self.motion)
	{
		HandPose was = self.now.pose[s];
		HandPose is = now.pose[s];
		Vec3 linear = (is.position - was.position) / dt;
		Vec3 angular = turned(was.rotation, is.rotation) / dt;
		motion.linear += (linear - motion.linear) * k;
		motion.angular += (angular - motion.angular) * k;
	}
}

<*
 The turn from `from` to `to` as an axis scaled by its angle in radians, the
 short way round.
*>
fn Vec3 turned(Quaternionf from, Quaternionf to) @local
{
	Quaternionf delta = to * from.conjugate();
	if (delta.l < 0) delta.v = -delta.v;
	Vec3 axis = delta.v.xyz;
	float s = axis.length();
	if (s < 1e-7f) return axis * 2.0f;
	return axis / s * (2.0f * math::atan2(s, delta.l));
}

fn char pulled(char before, HandButton button, float value) @local
{
	bool held = (before & button.bit()) != 0;
	return (held ? value > HAND_PULL_UP : value >= HAND_PULL_DOWN) ? button.bit() : 0;
}

<*
 Places both hands and the head in the world from the rig.

 @param rig : "Where the tracking space's origin sits in the world"
 @param yaw_degrees : "How far the tracking space is turned about +Y"
*>
fn void Hands.to_world(&self, Vec3 rig, float yaw_degrees)
{
	float yaw = math::deg_to_rad(yaw_degrees);
	Quaternionf turn = quaternion::from_axis_angle((Vec3){ 0, 1, 0 }, yaw);
	Quaternionf head = self.head.rotation;
	if (head.v == (float[<4>]){ 0, 0, 0, 0 }) head = { 0, 0, 0, 1 };
	self.head_world = { .position = rig + turn_y(self.head.position, yaw), .rotation = turn * head };
	foreach (&state : self.hand)
	{
		foreach (k, pose : state.now.pose)
		{
			Quaternionf rotation = pose.rotation;
			// A hand never seen has a zero quaternion; identity is the honest stand-in.
			if (rotation.v == (float[<4>]){ 0, 0, 0, 0 }) rotation = { 0, 0, 0, 1 };
			state.world[k] = { .position = rig + turn_y(pose.position, yaw), .rotation = turn * rotation };
			HandMotion motion = state.motion[k];
			state.world_motion[k] = { .linear = turn_y(motion.linear, yaw), .angular = turn_y(motion.angular, yaw) };
		}
	}
}

<*
 Places tracking space in the world: the reverse of `Hands.to_world`, for a
 pose that starts in the world, such as an emulated hand.
*>
fn HandPose from_world(HandPose world, Vec3 rig, float yaw_degrees)
{
	float yaw = math::deg_to_rad(yaw_degrees);
	Quaternionf back = quaternion::from_axis_angle((Vec3){ 0, 1, 0 }, -yaw);
	return { .position = turn_y(world.position - rig, -yaw), .rotation = back * world.rotation };
}

<*
 The rotation that turns -Z to `direction`. A zero direction is no turn.
*>
fn Quaternionf facing(Vec3 direction)
{
	float length = direction.length();
	if (length < 1e-6f) return { 0, 0, 0, 1 };
	Vec3 to = direction / length;
	Vec3 from = { 0, 0, -1 };
	float along = from.dot(to);
	if (along > 0.99999f) return { 0, 0, 0, 1 };
	// Straight back: half a turn about +Y.
	if (along < -0.99999f) return { 0, 1, 0, 0 };
	return quaternion::from_rotation(from, to);
}

// Where -Z points after `rotation`, the way an aim pose points.
fn Vec3 HandPose.forward(self) => self.rotation.rotate_vec3((Vec3){ 0, 0, -1 });

// `v` turned by `angle` radians about +Y, the way yaw turns the orbit camera.
fn Vec3 turn_y(Vec3 v, float angle)
{
	float c = math::cos(angle);
	float s = math::sin(angle);
	return { v.x * c + v.z * s, v.y, -v.x * s + v.z * c };
}

<*
 A node the engine keeps on a hand, every frame, in `Scene.tracked`.
*>
struct TrackedNode
{
	NodeId node;
	Hand hand;
	HandSpace space;
	// Hidden while the hand is disconnected. The engine's own grip and aim
	// groups are; a script's object keeps the visibility the script gave it.
	bool shown_with_hand;
}

<*
 Keeps a node on a hand from now on.

 Top-level only: the pose written is a world pose, and at the top level local
 and world are the same thing.

 @param shown_with_hand : "Hide the node while the hand is disconnected"
 @return "False when the node is gone or is not top-level"
*>
fn bool Scene.track_hand(&self, NodeId id, Hand hand, HandSpace space, bool shown_with_hand = true)
{
	Node* node = self.node(id);
	if (node == null || node.parent != self.root) return false;
	foreach (&entry : self.tracked)
	{
		if (entry.node != id) continue;
		entry.hand = hand;
		entry.space = space;
		entry.shown_with_hand = shown_with_hand;
		return true;
	}
	self.tracked.push({ .node = id, .hand = hand, .space = space, .shown_with_hand = shown_with_hand });
	return true;
}

<*
 Stops keeping a node on its hand. It stays where the hand last put it.

 @return "False when the node was not tracked"
*>
fn bool Scene.untrack_hand(&self, NodeId id)
{
	foreach (i, entry : self.tracked)
	{
		if (entry.node != id) continue;
		self.tracked.remove_at(i);
		return true;
	}
	return false;
}

<*
 Moves every tracked node onto its hand, and hides the engine's own while that
 hand is disconnected. A node that died or was moved under a parent is dropped,
 and one the solver owns is left to the solver.

 Called before the physics step, so a kinematic body on a hand reaches the
 solver where the hand is this frame.
*>
fn void Scene.update_tracked(&self, Hands* hands)
{
	// Backwards, so removing an entry does not skip the one after it.
	for (sz i = self.tracked.len(); i > 0; i--)
	{
		TrackedNode entry = self.tracked[i - 1];
		Node* node = self.node(entry.node);
		if (node == null || node.parent != self.root)
		{
			self.tracked.remove_at(i - 1);
			continue;
		}
		HandState* state = &hands.hand[entry.hand.ordinal];
		bool connected = state.now.connected;
		if (entry.shown_with_hand && node.visible != connected) self.set_visible(entry.node, connected);
		if (!connected || self.physics.owns_transform(entry.node)) continue;
		HandPose pose = state.world[entry.space.ordinal];
		node.position = pose.position;
		node.rotation = pose.rotation;
		self.mark_moved(entry.node);
	}
}

// Where an emulated hand sits along the pointer's ray, in metres.
const float EMULATED_REACH = 0.45f;

// The keys the emulated hands take, so a game sees them as the controller only.
const c3w::EventKey[*] EMULATED_KEYS = {
	KEY_1, KEY_2, KEY_3, KEY_4, Q, E, M, W, A, S, D,
	UP_ARROW, DOWN_ARROW, LEFT_ARROW, RIGHT_ARROW,
};

<*
 Both hands from a mouse and a keyboard, for working on a headset game at a
 desk. The right hand points where the pointer is; the left hangs low and to
 the left of the view.

 Right: left button trigger, right button squeeze, middle the stick click, 1 and
 2 are A and B, the arrows its stick. Left: Q trigger, E squeeze, 3 and 4 are X
 and Y, M menu, WASD its stick.

 @param [&in] camera : "The view; its target and yaw are the rig"
 @param [&in] input : "This frame's keyboard and mouse"
 @param width : "The target's width in pixels, or 0 when there is none"
*>
fn HandsReading emulate_hands(Camera* camera, InputState* input, uint width, uint height)
{
	Vec3 eye = camera.eye();
	Vec3 forward = -camera.orbit_dir();
	Vec3 right = forward.cross((Vec3){ 0, 1, 0 });
	right = right.length() > 1e-4f ? right.normalize() : (Vec3){ 1, 0, 0 };
	Vec3 up = right.cross(forward);

	HandsReading reading;
	HandReading* hand = &reading.hand[Hand.RIGHT.ordinal];
	Vec3 origin = eye + right * 0.2f - up * 0.2f;
	Vec3 aim = forward;
	if (width > 0 && height > 0 && input.mouse.inside)
	{
		collision::Ray ray = screen_ray(camera, input.mouse.x, input.mouse.y, width, height);
		origin = ray.origin;
		aim = ray.direction;
	}
	place_emulated(hand, { .position = origin + aim * EMULATED_REACH, .rotation = facing(aim) }, camera);
	hand.trigger = input.mouse.down ? 1 : 0;
	hand.squeeze = input.mouse.right ? 1 : 0;
	if (input.mouse.middle) hand.buttons |= HandButton.STICK.bit();
	if (input.down.has(KEY_1)) hand.buttons |= HandButton.A.bit();
	if (input.down.has(KEY_2)) hand.buttons |= HandButton.B.bit();
	hand.stick = keys_stick(input, UP_ARROW, DOWN_ARROW, LEFT_ARROW, RIGHT_ARROW);

	hand = &reading.hand[Hand.LEFT.ordinal];
	place_emulated(hand, { .position = eye - right * 0.25f - up * 0.3f + forward * EMULATED_REACH, .rotation = facing(forward) }, camera);
	hand.trigger = input.down.has(Q) ? 1 : 0;
	hand.squeeze = input.down.has(E) ? 1 : 0;
	if (input.down.has(KEY_3)) hand.buttons |= HandButton.X.bit();
	if (input.down.has(KEY_4)) hand.buttons |= HandButton.Y.bit();
	if (input.down.has(M)) hand.buttons |= HandButton.MENU.bit();
	hand.stick = keys_stick(input, W, S, A, D);
	return reading;
}

<*
 The head at a desk: the camera's eye, looking where the camera looks.

 @param [&in] camera : "The view; its target and yaw are the rig"
 @return "The head in tracking space"
*>
fn HandPose desk_head(Camera* camera)
{
	return from_world({ .position = camera.eye(), .rotation = facing(-camera.orbit_dir()) }, camera.target, camera.yaw);
}

fn void place_emulated(HandReading* hand, HandPose world, Camera* camera) @local
{
	HandPose local = from_world(world, camera.target, camera.yaw);
	hand.connected = true;
	hand.profile = "emulated";
	hand.pose = { local, local };
}

fn float[<2>] keys_stick(InputState* input, c3w::EventKey up, c3w::EventKey down, c3w::EventKey left, c3w::EventKey right) @local
{
	float x = (input.down.has(right) ? 1.0f : 0.0f) - (input.down.has(left) ? 1.0f : 0.0f);
	float y = (input.down.has(up) ? 1.0f : 0.0f) - (input.down.has(down) ? 1.0f : 0.0f);
	return { x, y };
}

<*
 The frame a game sees while its hands are emulated: without the keys and
 buttons the hands took.
*>
fn InputState without_emulated(InputState input)
{
	KeyBits taken;
	foreach (key : EMULATED_KEYS) taken.set(key);
	input.down = input.down.without(taken);
	input.pressed = input.pressed.without(taken);
	input.released = input.released.without(taken);
	input.mouse.down = false;
	input.mouse.right = false;
	input.mouse.middle = false;
	input.mouse.clicked = false;
	return input;
}
