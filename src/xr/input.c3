<*
 The Touch controllers through OpenXR actions: one action set, bound to the
 Touch profile and to the simple controller as a fallback, read once a frame
 into a `HandsReading` and handed to the tick.

 OpenXR's order is fixed: actions, then suggested bindings, then one attach per
 session, after which the set can no longer change.
*>
module three @feat(ANDROID);

import std::io;
import xr;

enum XrAct : char (String key, CInt kind)
{
	GRIP { "grip_pose", xr::ACTION_TYPE_POSE_INPUT },
	AIM { "aim_pose", xr::ACTION_TYPE_POSE_INPUT },
	TRIGGER { "trigger", xr::ACTION_TYPE_FLOAT_INPUT },
	SQUEEZE { "squeeze", xr::ACTION_TYPE_FLOAT_INPUT },
	STICK { "thumbstick", xr::ACTION_TYPE_VECTOR2F_INPUT },
	STICK_CLICK { "thumbstick_click", xr::ACTION_TYPE_BOOLEAN_INPUT },
	// A on the right hand, X on the left.
	PRIMARY { "primary", xr::ACTION_TYPE_BOOLEAN_INPUT },
	// B on the right hand, Y on the left.
	SECONDARY { "secondary", xr::ACTION_TYPE_BOOLEAN_INPUT },
	MENU { "menu", xr::ACTION_TYPE_BOOLEAN_INPUT },
	HAPTIC { "haptic", xr::ACTION_TYPE_VIBRATION_OUTPUT },
}

struct XrBinding
{
	XrAct act;
	ZString path;
}

const XrBinding[*] TOUCH_BINDINGS = {
	{ GRIP, "/user/hand/left/input/grip/pose" },
	{ GRIP, "/user/hand/right/input/grip/pose" },
	{ AIM, "/user/hand/left/input/aim/pose" },
	{ AIM, "/user/hand/right/input/aim/pose" },
	{ TRIGGER, "/user/hand/left/input/trigger/value" },
	{ TRIGGER, "/user/hand/right/input/trigger/value" },
	{ SQUEEZE, "/user/hand/left/input/squeeze/value" },
	{ SQUEEZE, "/user/hand/right/input/squeeze/value" },
	{ STICK, "/user/hand/left/input/thumbstick" },
	{ STICK, "/user/hand/right/input/thumbstick" },
	{ STICK_CLICK, "/user/hand/left/input/thumbstick/click" },
	{ STICK_CLICK, "/user/hand/right/input/thumbstick/click" },
	{ PRIMARY, "/user/hand/left/input/x/click" },
	{ PRIMARY, "/user/hand/right/input/a/click" },
	{ SECONDARY, "/user/hand/left/input/y/click" },
	{ SECONDARY, "/user/hand/right/input/b/click" },
	// The right hand's is the system's own button.
	{ MENU, "/user/hand/left/input/menu/click" },
	{ HAPTIC, "/user/hand/left/output/haptic" },
	{ HAPTIC, "/user/hand/right/output/haptic" },
};

const XrBinding[*] SIMPLE_BINDINGS = {
	{ GRIP, "/user/hand/left/input/grip/pose" },
	{ GRIP, "/user/hand/right/input/grip/pose" },
	{ AIM, "/user/hand/left/input/aim/pose" },
	{ AIM, "/user/hand/right/input/aim/pose" },
	// A float action on a click reads 0 or 1.
	{ TRIGGER, "/user/hand/left/input/select/click" },
	{ TRIGGER, "/user/hand/right/input/select/click" },
	{ MENU, "/user/hand/left/input/menu/click" },
	{ MENU, "/user/hand/right/input/menu/click" },
	{ HAPTIC, "/user/hand/left/output/haptic" },
	{ HAPTIC, "/user/hand/right/output/haptic" },
};

const String PROFILE_PREFIX = "/interaction_profiles/";

struct XrProfileName
{
	char[xr::MAX_PATH_LENGTH] text;
	// Into `text`, without PROFILE_PREFIX.
	String name;
}

struct XrInput
{
	xr::ActionSet set;
	xr::Action[XrAct::len] actions;
	// `/user/hand/left` and `/user/hand/right`, by `Hand`.
	xr::Path[2] hands;
	xr::Space[2] grip_spaces;
	xr::Space[2] aim_spaces;
	XrProfileName[2] profiles;
	// The last `Haptic.serial` sent, by `Hand`.
	uint[2] haptic_sent;
	bool ready;
	bool sync_failed;
}

<*
 Makes the actions, suggests both profiles' bindings, attaches the set, and
 makes the four pose spaces. A failure leaves the session without controllers.

 @return? xr::CALL_FAILED
*>
fn void? XrInput.open(&self, xr::Instance instance, xr::Session session)
{
	self.hands[Hand.LEFT.ordinal] = to_path(instance, "/user/hand/left")!;
	self.hands[Hand.RIGHT.ordinal] = to_path(instance, "/user/hand/right")!;

	xr::ActionSetCreateInfo set_info = { .type = xr::TYPE_ACTION_SET_CREATE_INFO };
	put_name(set_info.action_set_name[..], "gameplay");
	put_name(set_info.localized_action_set_name[..], "Gameplay");
	xr::check(xr::cmd.create_action_set(instance, &set_info, &self.set), "xrCreateActionSet")!;

	foreach (act : XrAct::values)
	{
		xr::ActionCreateInfo info = {
			.type = xr::TYPE_ACTION_CREATE_INFO,
			.action_type = act.kind,
			.count_subaction_paths = 2,
			.subaction_paths = &self.hands[0],
		};
		put_name(info.action_name[..], act.key);
		put_name(info.localized_action_name[..], act.key);
		xr::check(xr::cmd.create_action(self.set, &info, &self.actions[act.ordinal]), "xrCreateAction")!;
	}

	// One profile the runtime refuses must not take the other with it.
	bool took = self.suggest(instance, "/interaction_profiles/oculus/touch_controller", TOUCH_BINDINGS[..]);
	took |= self.suggest(instance, "/interaction_profiles/khr/simple_controller", SIMPLE_BINDINGS[..]);
	if (!took) return xr::CALL_FAILED~;

	xr::SessionActionSetsAttachInfo attach = {
		.type = xr::TYPE_SESSION_ACTION_SETS_ATTACH_INFO,
		.count_action_sets = 1,
		.action_sets = &self.set,
	};
	xr::check(xr::cmd.attach_session_action_sets(session, &attach), "xrAttachSessionActionSets")!;

	foreach (i, hand : self.hands)
	{
		self.grip_spaces[i] = self.pose_space(session, XrAct.GRIP, hand)!;
		self.aim_spaces[i] = self.pose_space(session, XrAct.AIM, hand)!;
	}
	self.ready = true;
	io::printn("xr: controllers ready");
}

<*
 @return "Whether the runtime took the profile"
*>
fn bool XrInput.suggest(&self, xr::Instance instance, ZString profile, XrBinding[] bindings)
{
	xr::Path profile_path = to_path(instance, profile) ?? xr::NULL_PATH;
	if (profile_path == xr::NULL_PATH) return false;
	xr::ActionSuggestedBinding[32] suggested;
	uint count;
	foreach (binding : bindings)
	{
		if (count == suggested.len) break;
		if (try path = to_path(instance, binding.path))
		{
			suggested[count++] = { .action = self.actions[binding.act.ordinal], .binding = path };
		}
	}
	xr::InteractionProfileSuggestedBinding info = {
		.type = xr::TYPE_INTERACTION_PROFILE_SUGGESTED_BINDING,
		.interaction_profile = profile_path,
		.count_suggested_bindings = count,
		.suggested_bindings = &suggested[0],
	};
	return @ok(xr::check(xr::cmd.suggest_interaction_profile_bindings(instance, &info), profile.str_view()));
}

<*
 @return? xr::CALL_FAILED
*>
fn xr::Space? XrInput.pose_space(&self, xr::Session session, XrAct act, xr::Path hand)
{
	xr::ActionSpaceCreateInfo info = {
		.type = xr::TYPE_ACTION_SPACE_CREATE_INFO,
		.action = self.actions[act.ordinal],
		.subaction_path = hand,
		.pose_in_action_space = { .orientation = { .w = 1 } },
	};
	xr::Space space;
	xr::check(xr::cmd.create_action_space(session, &info, &space), "xrCreateActionSpace")!;
	return space;
}

<*
 This frame's controllers, poses at `time` in `base`. All zero, and so
 disconnected, while the session is not focused: the system menu has the
 controllers then.

 @param [&out] out : "Filled in full"
*>
fn void XrInput.read(&self, xr::Session session, xr::Space base, xr::Time time, bool focused, HandsReading* out)
{
	*out = { };
	if (!self.ready || !focused) return;
	xr::ActiveActionSet active = { .action_set = self.set, .subaction_path = xr::NULL_PATH };
	xr::ActionsSyncInfo sync = {
		.type = xr::TYPE_ACTIONS_SYNC_INFO,
		.count_active_action_sets = 1,
		.active_action_sets = &active,
	};
	xr::Result synced = xr::cmd.sync_actions(session, &sync);
	// A success code: focus went between the frame's start and here.
	if (synced == xr::SESSION_NOT_FOCUSED) return;
	if (synced < 0)
	{
		if (!self.sync_failed) (void)xr::check(synced, "xrSyncActions");
		self.sync_failed = true;
		return;
	}

	HandsReading reading;
	defer *out = reading;
	foreach (i, &hand : reading.hand)
	{
		xr::Path sub = self.hands[i];
		bool left = i == Hand.LEFT.ordinal;
		hand.trigger = self.float_state(session, TRIGGER, sub);
		hand.squeeze = self.float_state(session, SQUEEZE, sub);
		hand.stick = self.stick_state(session, sub);
		char buttons;
		if (self.bool_state(session, STICK_CLICK, sub)) buttons |= HandButton.STICK.bit();
		if (self.bool_state(session, PRIMARY, sub)) buttons |= (left ? HandButton.X : HandButton.A).bit();
		if (self.bool_state(session, SECONDARY, sub)) buttons |= (left ? HandButton.Y : HandButton.B).bit();
		if (self.bool_state(session, MENU, sub)) buttons |= HandButton.MENU.bit();
		hand.buttons = buttons;

		Located grip = locate(self.grip_spaces[i], base, time);
		Located aim = locate(self.aim_spaces[i], base, time);
		if (!aim.tracked) aim = grip;
		hand.pose = { grip.pose, aim.pose };
		hand.motion = { grip.motion, aim.motion };
		hand.measured = grip.measured && aim.measured;
		hand.connected = grip.tracked && self.pose_active(session, sub);
		hand.profile = self.profiles[i].name;
	}
}

fn float XrInput.float_state(&self, xr::Session session, XrAct act, xr::Path sub)
{
	xr::ActionStateGetInfo info = { .type = xr::TYPE_ACTION_STATE_GET_INFO, .action = self.actions[act.ordinal], .subaction_path = sub };
	xr::ActionStateFloat state = { .type = xr::TYPE_ACTION_STATE_FLOAT };
	if (xr::cmd.get_action_state_float(session, &info, &state) < 0 || state.is_active == 0) return 0;
	return state.current_state;
}

fn bool XrInput.bool_state(&self, xr::Session session, XrAct act, xr::Path sub)
{
	xr::ActionStateGetInfo info = { .type = xr::TYPE_ACTION_STATE_GET_INFO, .action = self.actions[act.ordinal], .subaction_path = sub };
	xr::ActionStateBoolean state = { .type = xr::TYPE_ACTION_STATE_BOOLEAN };
	if (xr::cmd.get_action_state_boolean(session, &info, &state) < 0 || state.is_active == 0) return false;
	return state.current_state != 0;
}

fn float[<2>] XrInput.stick_state(&self, xr::Session session, xr::Path sub)
{
	xr::ActionStateGetInfo info = { .type = xr::TYPE_ACTION_STATE_GET_INFO, .action = self.actions[XrAct.STICK.ordinal], .subaction_path = sub };
	xr::ActionStateVector2f state = { .type = xr::TYPE_ACTION_STATE_VECTOR2F };
	if (xr::cmd.get_action_state_vector2f(session, &info, &state) < 0 || state.is_active == 0) return { 0, 0 };
	return { state.current_state.x, state.current_state.y };
}

fn bool XrInput.pose_active(&self, xr::Session session, xr::Path sub)
{
	xr::ActionStateGetInfo info = { .type = xr::TYPE_ACTION_STATE_GET_INFO, .action = self.actions[XrAct.GRIP.ordinal], .subaction_path = sub };
	xr::ActionStatePose state = { .type = xr::TYPE_ACTION_STATE_POSE };
	return xr::cmd.get_action_state_pose(session, &info, &state) >= 0 && state.is_active != 0;
}

// Where a space is at a time, and how fast it is moving.
struct Located
{
	// Both its position and its orientation are known.
	bool tracked;
	HandPose pose;
	// Both its linear and its angular velocity are known.
	bool measured;
	HandMotion motion;
}

fn Located locate(xr::Space space, xr::Space base, xr::Time time) @local
{
	xr::SpaceVelocity velocity = { .type = xr::TYPE_SPACE_VELOCITY };
	xr::SpaceLocation location = { .type = xr::TYPE_SPACE_LOCATION, .next = &velocity };
	if (xr::cmd.locate_space(space, base, time, &location) < 0) return { };
	xr::Flags64 needed = xr::SPACE_LOCATION_ORIENTATION_VALID_BIT | xr::SPACE_LOCATION_POSITION_VALID_BIT;
	if ((location.location_flags & needed) != needed) return { };
	xr::Posef pose = location.pose;
	Located out = {
		.tracked = true,
		.pose = {
			.position = { pose.position.x, pose.position.y, pose.position.z },
			.rotation = { pose.orientation.x, pose.orientation.y, pose.orientation.z, pose.orientation.w },
		},
	};
	xr::Flags64 moving = xr::SPACE_VELOCITY_LINEAR_VALID_BIT | xr::SPACE_VELOCITY_ANGULAR_VALID_BIT;
	if ((velocity.velocity_flags & moving) != moving) return out;
	out.measured = true;
	xr::Vector3f l = velocity.linear_velocity;
	xr::Vector3f a = velocity.angular_velocity;
	out.motion = { .linear = { l.x, l.y, l.z }, .angular = { a.x, a.y, a.z } };
	return out;
}

<*
 Sends each hand's vibration once per request. Amplitude 0 stops one.
*>
fn void XrInput.send_haptics(&self, xr::Session session, Hands* hands, bool focused)
{
	if (!self.ready) return;
	foreach (i, &state : hands.hand)
	{
		Haptic haptic = state.haptic;
		if (haptic.serial == self.haptic_sent[i]) continue;
		self.haptic_sent[i] = haptic.serial;
		if (!focused) continue;
		xr::HapticActionInfo info = {
			.type = xr::TYPE_HAPTIC_ACTION_INFO,
			.action = self.actions[XrAct.HAPTIC.ordinal],
			.subaction_path = self.hands[i],
		};
		if (haptic.amplitude <= 0)
		{
			(void)xr::check(xr::cmd.stop_haptic_feedback(session, &info), "xrStopHapticFeedback");
			continue;
		}
		xr::HapticVibration vibration = {
			.type = xr::TYPE_HAPTIC_VIBRATION,
			.duration = haptic.seconds > 0 ? (xr::Duration)((double)haptic.seconds * 1e9) : xr::MIN_HAPTIC_DURATION,
			.amplitude = haptic.amplitude,
		};
		(void)xr::check(xr::cmd.apply_haptic_feedback(session, &info, (xr::HapticBaseHeader*)&vibration),
			"xrApplyHapticFeedback");
	}
}

<*
 Asks which controller each hand holds now, after the runtime said it changed.
*>
fn void XrInput.note_profiles(&self, xr::Instance instance, xr::Session session)
{
	if (!self.ready) return;
	foreach (i, &profile : self.profiles)
	{
		profile.name = "";
		xr::InteractionProfileState state = { .type = xr::TYPE_INTERACTION_PROFILE_STATE };
		if (xr::cmd.get_current_interaction_profile(session, self.hands[i], &state) < 0) continue;
		if (state.interaction_profile != xr::NULL_PATH)
		{
			uint count;
			if (xr::cmd.path_to_string(instance, state.interaction_profile, profile.text.len, &count, &profile.text[0]) >= 0)
			{
				String full = ((ZString)&profile.text).str_view();
				profile.name = full.starts_with(PROFILE_PREFIX) ? full[PROFILE_PREFIX.len..] : full;
			}
		}
		io::printfn("xr: %s hand %s", i == Hand.LEFT.ordinal ? "left" : "right",
			profile.name.len > 0 ? profile.name : "has no controller");
	}
}

fn void XrInput.close(&self)
{
	foreach (space : self.grip_spaces)
	{
		if (space != null) xr::cmd.destroy_space(space);
	}
	foreach (space : self.aim_spaces)
	{
		if (space != null) xr::cmd.destroy_space(space);
	}
	// Takes its actions with it.
	if (self.set != null) xr::cmd.destroy_action_set(self.set);
	*self = { };
}

<*
 @return? xr::CALL_FAILED
*>
fn xr::Path? to_path(xr::Instance instance, ZString text) @local
{
	xr::Path path;
	xr::check(xr::cmd.string_to_path(instance, text, &path), "xrStringToPath")!;
	return path;
}

<*
 @require text.len < dest.len : "Name too long"
*>
fn void put_name(char[] dest, String text) @local
{
	dest[:text.len] = text[..];
	dest[text.len] = 0;
}
