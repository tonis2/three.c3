<*
 The hand controllers' state, off a headset: edges, the trigger's two
 thresholds, a disconnect, the rig, and the nodes kept on a hand.

	`c3c test --test-noleak --test-filter three_tests::hands`
*>
module three_tests::hands;

import three;
import std::core::test;
import std::math;
import std::math::vector;
import std::math::quaternion;

fn three::HandsReading right_hand(char buttons = 0, float trigger = 0)
{
	three::HandsReading reading;
	reading.hand[three::Hand.RIGHT.ordinal] = {
		.connected = true,
		.buttons = buttons,
		.trigger = trigger,
		.pose = { { .rotation = { 0, 0, 0, 1 } }, { .rotation = { 0, 0, 0, 1 } } },
	};
	return reading;
}

macro bool close(Vec3 a, Vec3 b) => (a - b).length() < 0.0001f;

fn void a_click_has_one_press_and_one_release() @test
{
	three::Hands hands;
	char a = three::HandButton.A.bit();
	hands.step(right_hand(a));
	three::HandState* right = &hands.hand[three::Hand.RIGHT.ordinal];
	test::eq(right.pressed, a);
	test::eq(right.down, a);
	hands.step(right_hand(a));
	test::eq(right.pressed, (char)0);
	test::eq(right.down, a);
	hands.step(right_hand());
	test::eq(right.released, a);
	test::eq(right.down, (char)0);
	hands.step(right_hand());
	test::eq(right.released, (char)0);
}

fn void the_trigger_holds_between_its_two_thresholds() @test
{
	three::Hands hands;
	char bit = three::HandButton.TRIGGER.bit();
	three::HandState* right = &hands.hand[three::Hand.RIGHT.ordinal];
	hands.step(right_hand(trigger: 0.5f));
	test::eq(right.down & bit, (char)0);
	hands.step(right_hand(trigger: 0.65f));
	test::eq(right.pressed & bit, bit);
	// Below the press point, above the release point: still held.
	hands.step(right_hand(trigger: 0.5f));
	test::eq(right.down & bit, bit);
	hands.step(right_hand(trigger: 0.35f));
	test::eq(right.released & bit, bit);
}

fn void a_disconnect_lets_go_of_everything() @test
{
	three::Hands hands;
	char held = three::HandButton.B.bit() | three::HandButton.SQUEEZE.bit();
	three::HandsReading reading = right_hand(three::HandButton.B.bit());
	reading.hand[three::Hand.RIGHT.ordinal].squeeze = 1;
	hands.step(reading);
	three::HandState* right = &hands.hand[three::Hand.RIGHT.ordinal];
	test::eq(right.down, held);
	hands.step({ });
	test::eq(right.released, held);
	test::eq(right.down, (char)0);
}

fn void a_synthetic_press_connects_the_hand() @test
{
	three::Hands hands;
	hands.synthetic[three::Hand.LEFT.ordinal] = { .used = true, .buttons = three::HandButton.X.bit() };
	hands.step({ });
	three::HandState* left = &hands.hand[three::Hand.LEFT.ordinal];
	test::@check(left.now.connected, "a held synthetic button should connect the hand");
	test::eq(left.pressed, three::HandButton.X.bit());
	test::eq(left.now.profile, "synthetic");
}

fn void the_rig_places_the_hands() @test
{
	three::Hands hands;
	three::HandsReading reading = right_hand();
	reading.hand[three::Hand.RIGHT.ordinal].pose[three::HandSpace.AIM.ordinal].position = { 0, 1, -1 };
	hands.step(reading);
	// A quarter turn left: the player faces -X, so a metre ahead is a metre along -X.
	hands.to_world({ 1, 0, 2 }, 90);
	three::HandPose aim = hands.hand[three::Hand.RIGHT.ordinal].world[three::HandSpace.AIM.ordinal];
	test::@check(close(aim.position, { 0, 1, 2 }), "aim at (%f, %f, %f)", aim.position.x, aim.position.y, aim.position.z);
	Vec3 forward = aim.forward();
	test::@check(close(forward, { -1, 0, 0 }), "pointing (%f, %f, %f)", forward.x, forward.y, forward.z);
}

fn void from_world_undoes_to_world() @test
{
	three::HandPose world = { .position = { 3, 1.5, -2 }, .rotation = quaternion::from_axis_angle((Vec3){ 1, 0, 0 }, 0.3f) };
	three::HandPose local = three::from_world(world, { 1, 0, 2 }, 40);
	three::Hands hands;
	three::HandsReading reading = right_hand();
	reading.hand[three::Hand.RIGHT.ordinal].pose[three::HandSpace.GRIP.ordinal] = local;
	hands.step(reading);
	hands.to_world({ 1, 0, 2 }, 40);
	three::HandPose back = hands.hand[three::Hand.RIGHT.ordinal].world[three::HandSpace.GRIP.ordinal];
	test::@check(close(back.position, world.position), "round trip moved the hand");
	test::@check(close(back.forward(), world.forward()), "round trip turned the hand");
}

fn void a_tracked_node_follows_its_hand_and_hides_without_it() @test
{
	three::Scene scene;
	scene.init();
	defer scene.free();
	three::NodeId grip = scene.add_group(name: "grip");
	test::@check(scene.track_hand(grip, three::Hand.RIGHT, three::HandSpace.GRIP), "a top-level group can be tracked");

	three::Hands hands;
	three::HandsReading reading = right_hand();
	reading.hand[three::Hand.RIGHT.ordinal].pose[three::HandSpace.GRIP.ordinal].position = { 0.2, 1.1, -0.3 };
	hands.step(reading);
	hands.to_world({ 0, 0, 0 }, 0);
	scene.update_tracked(&hands);
	test::@check(close(scene.node(grip).position, { 0.2, 1.1, -0.3 }), "the grip was not placed");
	test::@check(scene.node(grip).visible, "a connected hand's node shows");

	hands.step({ });
	scene.update_tracked(&hands);
	test::@check(!scene.node(grip).visible, "a disconnected hand's node hides");
}

fn void only_top_level_nodes_are_tracked_and_dead_ones_are_dropped() @test
{
	three::Scene scene;
	scene.init();
	defer scene.free();
	three::NodeId parent = scene.add_group();
	three::NodeId child = scene.add_group(parent);
	test::@check(!scene.track_hand(child, three::Hand.LEFT, three::HandSpace.AIM), "a child cannot be tracked");

	three::NodeId grip = scene.add_group();
	scene.track_hand(grip, three::Hand.LEFT, three::HandSpace.GRIP);
	test::eq(scene.tracked.len(), 1);
	scene.kill(grip);
	three::Hands hands;
	scene.update_tracked(&hands);
	test::eq(scene.tracked.len(), 0);
}
