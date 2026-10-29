<*
 glTF node animation — `game.md` G3, S4 through S6.

	`c3c test --trust=full --test-noleak --test-filter three_tests::animation`

 The fixture is `test/fixtures/hierarchy.glb`, whose three clips exist to
 separate three failures that all look like "the animation plays":

 - `slide` is LINEAR and its midpoint is a value no key holds, so a sampler that
   snaps to the nearest key fails it.
 - `spin` is a LINEAR **rotation**, where the spec means slerp. A component-wise
   mix of the same two quaternions is a shorter turn through a non-unit
   quaternion — smooth, plausible, and wrong by six degrees at the midpoint.
 - `blink` is STEP, which a LINEAR-only implementation renders as a perfectly
   smooth ramp.

 Every check is on a world position or a matrix rather than on a sampled number,
 because the sampled number is only half the job: the other half is that it
 reaches the right node, and the map from a glTF channel's node index to a
 `NodeId` is built somewhere else entirely (`Scene.start_player`).
*>
module three_tests::animation;

import three;
import three_tests::device;
import vk;
import std::core::test;
import std::io::file;
import std::math;
import std::math::vector;
import std::math::matrix;
import std::math::quaternion;

const String FIXTURE = "test/fixtures/hierarchy.glb";

const uint W = 200;
const uint H = 150;

macro @with_pass(; @body(three::Renderer* renderer))
{
	three::Renderer* renderer = device::borrow(W, H);
	defer device::release();

	@body(renderer);
}

fn three::NodeId named(three::Scene* scene, String name)
{
	foreach (i, &node : scene.nodes)
	{
		if (node.alive && node.name == name)
		{
			return { .index = (uint)i, .generation = node.generation };
		}
	}
	test::@check(false, "no node called '%s' in the scene", name);
	return three::NO_NODE;
}

<*
 The layer playing a clip on a character, by the clip's name — what these checks
 ask the stack about. Null when that clip is not on it.

 Looked up afresh each time it is wanted: a layer that fades out is removed and
 the ones after it move down, so a pointer held across a step can point at the
 wrong clip.
*>
fn three::AnimationLayer* layer_of(three::Renderer* renderer, three::NodeId root, String name)
{
	three::AnimationPlayer* player = renderer.pass.scene.player(root);
	if (player == null) return null;
	three::Asset* asset = renderer.pass.assets.slot(player.asset);
	if (asset == null) return null;
	for (uint i = 0; i < player.layer_count; i++)
	{
		three::AnimationLayer* layer = &player.layers[i];
		if (layer.clip >= 0 && asset.clips[layer.clip].name == name) return layer;
	}
	return null;
}

// The layer that is most of the picture.
fn three::AnimationLayer* top_layer(three::Scene* scene, three::NodeId root)
{
	three::AnimationPlayer* player = scene.player(root);
	if (player == null) return null;
	int top = player.dominant();
	return top < 0 ? null : &player.layers[top];
}

fn bool near(Vec3 got, Vec3 want, float tolerance = 0.001f)
{
	return math::abs(got.x - want.x) < tolerance
		&& math::abs(got.y - want.y) < tolerance
		&& math::abs(got.z - want.z) < tolerance;
}

// ============================================================================
// The data — S4
// ============================================================================

<*
 A file's clips are named and measured without a keyframe being read.

 The same rule as G3/S3 one level along: names and durations are in the JSON —
 a clip's extent comes from its time accessor's required `min`/`max` — so
 "does this character have a walk cycle" is a free question and reading the
 curves is what costs.

 `channels.len() == 0` is the assertion that says the curves have *not* been
 read. It is the same shape as `loading_a_file_uploads_nothing`: an absence, and
 the only kind of check that notices the lazy path quietly becoming eager.
*>
fn void a_files_clips_are_named_without_being_read() @test
{
	test::@check(file::is_file(FIXTURE), "%s is missing — regenerate it with test/fixtures/make_hierarchy.py", FIXTURE);

	@with_pass(; three::Renderer* renderer)
	{
		three::AssetId id = renderer.pass.assets.load(&renderer.gpu, FIXTURE)!!;
		three::Asset* asset = renderer.pass.assets.slot(id);

		test::@check(asset.clips.len() == 3, "the fixture's three clips came back as %d", asset.clips.len());

		foreach (&clip : asset.clips)
		{
			test::@check(clip.name.len > 0, "a clip came back unnamed");
			test::@check(
				math::abs(clip.duration - 2.0f) < 0.0001f,
				"`%s` runs for %f seconds, expected 2", clip.name, clip.duration
			);
			test::@check(!clip.loaded, "`%s` read its curves during the load", clip.name);
			test::@check(clip.channels.len() == 0, "`%s` has %d channels before anything played it",
				clip.name, clip.channels.len());
		}
	};
}

<*
 Playing reads that clip's curves, and only that clip's.

 A character with eleven clips reads the one that plays. The other two staying at
 zero channels is the half of the assertion that says so — a loader that read
 everything on the first play would pass a check that only looked at `slide`.
*>
fn void playing_reads_one_clips_curves() @test
{
	@with_pass(; three::Renderer* renderer)
	{
		three::Assets* assets = &renderer.pass.assets;
		three::Scene* scene = renderer.pass.scene;

		three::AssetId id = assets.load(&renderer.gpu, FIXTURE)!!;
		three::NodeId prop = scene.instantiate(id, scene.root, "prop");

		test::@check(scene.play(prop, "slide"), "`slide` would not play");

		foreach (&clip : assets.slot(id).clips)
		{
			if (clip.name == "slide")
			{
				test::@check(clip.channels.len() == 1, "`slide` read %d channels, expected 1", clip.channels.len());
				test::@check(clip.loaded, "`slide` played without being marked read");
			}
			else
			{
				test::@check(clip.channels.len() == 0,
					"`%s` read its curves when `slide` was the one played", clip.name);
			}
		}
	};
}

<*
 A clip that is not there is a false, not a fault.

 "Which animations does this have" is a question a script can ask —
 `mesh.animations` — so asking for one that is not there is a mistake the script
 can see and correct, and a thrown exception in an animation callback is a
 stopped game.
*>
fn void a_clip_that_is_not_there_answers_no() @test
{
	@with_pass(; three::Renderer* renderer)
	{
		three::Scene* scene = renderer.pass.scene;
		three::AssetId id = renderer.pass.assets.load(&renderer.gpu, FIXTURE)!!;
		three::NodeId prop = scene.instantiate(id, scene.root, "prop");

		test::@check(!scene.play(prop, "moonwalk"), "a clip the file does not have played anyway");
		test::@check(!scene.play(scene.root, "slide"), "a subtree with no player played a clip");
	};
}

// ============================================================================
// Sampling — S4
// ============================================================================

<*
 A LINEAR channel interpolates, and it reaches the node the channel names.

 `slide` moves `tip` from x=1 to x=3 over two seconds. At one second the correct
 local x is 2, which **no keyframe holds** — a sampler that snapped to the
 nearest key would report 1 or 3 and look like it was working at both ends.

 Asserted in world space, which is what makes it a test of the channel *and* of
 the target map: `tip` sits under `arm` (scale 2) under `pivot` (translate 2,
 quarter turn about +Y), so a local x of 2 lands at (2, 0, -4). Writing the value
 into the wrong node would leave `tip` where the file put it, at (2, 0, -2).
*>
fn void a_linear_channel_interpolates_between_keys() @test
{
	@with_pass(; three::Renderer* renderer)
	{
		three::Scene* scene = renderer.pass.scene;

		three::AssetId id = renderer.pass.assets.load(&renderer.gpu, FIXTURE)!!;
		three::NodeId prop = scene.instantiate(id, scene.root, "prop");
		three::NodeId tip = named(scene, "tip");

		// Not looping, so that the last step lands on the final key rather than
		// wrapping to the first — t=2 and t=0 are the same instant of a looping
		// clip, and this test is about interpolation, not about the wrap.
		test::@check(scene.play(prop, "slide", loop: false), "`slide` would not play");

		// t = 0: the first key, x = 1 local, which is where the file's own TRS
		// already put it.
		scene.update_world_matrices();
		Vec3 at_start = scene.node(tip).world_position();
		test::@check(near(at_start, { 2, 0, -2 }),
			"at t=0 `tip` is at (%.3f, %.3f, %.3f), expected (2, 0, -2)", at_start.x, at_start.y, at_start.z);

		scene.step_animations(1.0f);
		scene.update_world_matrices();
		Vec3 halfway = scene.node(tip).world_position();
		test::@check(near(halfway, { 2, 0, -4 }),
			"at t=1 `tip` is at (%.3f, %.3f, %.3f), expected (2, 0, -4) — local x should be 2, which is not a key",
			halfway.x, halfway.y, halfway.z);

		scene.step_animations(1.0f);
		scene.update_world_matrices();
		Vec3 at_end = scene.node(tip).world_position();
		test::@check(near(at_end, { 2, 0, -6 }),
			"at t=2 `tip` is at (%.3f, %.3f, %.3f), expected (2, 0, -6)", at_end.x, at_end.y, at_end.z);
	};
}

<*
 A LINEAR rotation channel slerps.

 `spin` turns `arm` from 0° to 90° about +Y over the first second. At half a
 second the answer is 45°, and this is the one case where "interpolate the
 numbers" and "interpolate the rotation" differ enough to see: mixing the two
 quaternions component-wise and normalizing gives **45° as well** for a 90°
 arc — the two agree at the midpoint of any arc — so the midpoint is not where
 the difference shows.

 So this checks a *quarter* of the way instead. Slerp at t=0.25 of a 90° arc is
 22.5°; a normalized component-wise mix is 22.06°, which is half a degree out and
 grows with the arc. The tolerance below is tight enough to tell them apart and
 loose enough to survive float error, and `tip`'s two-unit lever arm turns the
 angular difference into something a position comparison can hold.
*>
fn void a_rotation_channel_takes_the_spherical_path() @test
{
	@with_pass(; three::Renderer* renderer)
	{
		three::Scene* scene = renderer.pass.scene;

		three::AssetId id = renderer.pass.assets.load(&renderer.gpu, FIXTURE)!!;
		three::NodeId prop = scene.instantiate(id, scene.root, "prop");
		three::NodeId arm = named(scene, "arm");

		test::@check(scene.play(prop, "spin"), "`spin` would not play");

		scene.step_animations(0.25f);

		Quaternionf sampled = scene.node(arm).rotation;
		float angle = 2.0f * math::acos(sampled.l < -1 ? -1.0f : (sampled.l > 1 ? 1.0f : sampled.l));
		float expected = (float)math::PI * 0.25f * 0.5f; // 22.5 degrees

		test::@check(
			math::abs(angle - expected) < 0.002f,
			"a quarter into a 90 degree arc the rotation is %f radians, expected %f — a component-wise mix gives %f",
			angle, expected, 0.3851f
		);
		test::@check(
			math::abs(sampled.length() - 1.0f) < 0.0001f,
			"the sampled rotation has length %f; a quaternion that is not unit shears the mesh", sampled.length()
		);
	};
}

<*
 A STEP channel holds its key.

 `blink` scales `loose` by 1 until t=1 and by 3 after it. At t=0.5 a LINEAR
 sampler gives 2, which is a perfectly smooth animation of exactly the wrong
 thing — the failure has no visual signature at all beyond "it eases when it
 should pop".
*>
fn void a_step_channel_does_not_interpolate() @test
{
	@with_pass(; three::Renderer* renderer)
	{
		three::Scene* scene = renderer.pass.scene;

		three::AssetId id = renderer.pass.assets.load(&renderer.gpu, FIXTURE)!!;
		three::NodeId prop = scene.instantiate(id, scene.root, "prop");
		three::NodeId loose = named(scene, "loose");

		test::@check(scene.play(prop, "blink"), "`blink` would not play");

		scene.step_animations(0.5f);
		Vec3 held = scene.node(loose).scale;
		test::@check(near(held, { 1, 1, 1 }),
			"halfway to the second key a STEP channel reports (%.3f, %.3f, %.3f), expected (1, 1, 1)",
			held.x, held.y, held.z);

		scene.step_animations(0.6f);
		Vec3 stepped = scene.node(loose).scale;
		test::@check(near(stepped, { 3, 3, 3 }),
			"past the second key a STEP channel reports (%.3f, %.3f, %.3f), expected (3, 3, 3)",
			stepped.x, stepped.y, stepped.z);
	};
}

// ============================================================================
// The player is per instance — S5
// ============================================================================

<*
 **Two copies of one asset animate at different phases.**

 `game.md` G3/S5's whole claim, and the reason the player is not on the asset.
 Two props, both playing `slide`, one stepped twice as far: if the time lived
 beside the keyframes they would be in lockstep and this is the only test that
 could tell.

 The clips are still shared — one read of the curves for both — which the second
 half asserts, because "per instance" done by copying the keyframes would pass
 the first half and defeat the point.
*>
fn void two_copies_animate_at_different_phases() @test
{
	@with_pass(; three::Renderer* renderer)
	{
		three::Assets* assets = &renderer.pass.assets;
		three::Scene* scene = renderer.pass.scene;

		three::AssetId id = assets.load(&renderer.gpu, FIXTURE)!!;
		three::NodeId one = scene.instantiate(id, scene.root, "one");
		three::NodeId two = scene.instantiate(id, scene.root, "two");

		test::@check(scene.play(one, "slide"), "the first copy would not play");
		test::@check(scene.play(two, "slide"), "the second copy would not play");

		// Step the whole scene once, then the first copy's player alone — which
		// is what a game does when two characters start walking at different
		// moments.
		scene.step_animations(0.5f);
		scene.player(one).advance(scene, assets, 0.5f);

		float ahead = top_layer(scene, one).time;
		float behind = top_layer(scene, two).time;
		test::@check(math::abs(ahead - 1.0f) < 0.0001f, "the first copy is at t=%f, expected 1", ahead);
		test::@check(math::abs(behind - 0.5f) < 0.0001f, "the second copy is at t=%f, expected 0.5", behind);

		// One copy of the curves, two players over it.
		uint read = 0;
		foreach (&clip : assets.slot(id).clips)
		{
			if (clip.channels.len() > 0) read++;
		}
		test::@check(read == 1, "%d clips read their curves for two copies of one asset", read);
		test::@check(scene.players.len() == 2, "%d players for two instantiations", scene.players.len());
	};
}

<*
 A player goes when its subtree does.

 The player holds a `NodeId` map into the scene, so one outliving its nodes would
 be writing sampled transforms into slots that something else now occupies —
 which is a node moving on its own with no code anywhere that moves it.
*>
fn void a_player_dies_with_its_subtree() @test
{
	@with_pass(; three::Renderer* renderer)
	{
		three::Scene* scene = renderer.pass.scene;

		three::AssetId id = renderer.pass.assets.load(&renderer.gpu, FIXTURE)!!;
		three::NodeId one = scene.instantiate(id, scene.root, "one");
		three::NodeId two = scene.instantiate(id, scene.root, "two");
		scene.play(one, "slide");
		scene.play(two, "slide");

		test::@check(scene.players.len() == 2, "%d players before the removal", scene.players.len());

		scene.remove(one);
		test::@check(scene.players.len() == 1, "%d players after removing one subtree", scene.players.len());
		test::@check(scene.player(one) == null, "the removed subtree still has a player");
		test::@check(scene.player(two) != null, "the surviving subtree lost its player");

		// And stepping is still fine, which is the thing a dangling player would
		// have broken loudly rather than subtly.
		scene.step_animations(0.5f);

		scene.remove(two);
		test::@check(scene.players.len() == 0, "%d players after removing both", scene.players.len());
		scene.step_animations(0.5f);
	};
}

<*
 An asset with no clips holds no players.

 A scene of ten thousand crates should carry no animation state at all. Worth an
 assertion because the cost of getting it wrong is invisible — everything works,
 there is just a list as long as the scene.
*>
fn void an_asset_with_no_clips_costs_no_player() @test
{
	@with_pass(; three::Renderer* renderer)
	{
		three::Scene* scene = renderer.pass.scene;

		three::AssetId id = renderer.pass.assets.load(&renderer.gpu, "test/fixtures/textured.glb")!!;
		scene.instantiate(id, scene.root, "crate");
		scene.instantiate(id, scene.root, "another");

		test::@check(scene.players.len() == 0,
			"a file with no animations produced %d players", scene.players.len());
		test::@check(!scene.step_animations(0.5f), "a scene with nothing to animate reported that it was animating");
	};
}

// ============================================================================
// Time — S6
// ============================================================================

<*
 A looping clip wraps to the pose it started in.

 Two seconds of `slide` and one loop later, the value has to be the first key
 again rather than the last. The failure mode is a loop implemented as "clamp
 then reset next frame", which holds the final pose for one frame — a visible
 hitch once per cycle, and the hardest kind of animation bug to catch by looking.
*>
fn void a_loop_wraps_to_the_same_pose() @test
{
	@with_pass(; three::Renderer* renderer)
	{
		three::Scene* scene = renderer.pass.scene;

		three::AssetId id = renderer.pass.assets.load(&renderer.gpu, FIXTURE)!!;
		three::NodeId prop = scene.instantiate(id, scene.root, "prop");
		three::NodeId tip = named(scene, "tip");

		scene.play(prop, "slide", loop: true);
		Vec3 first = scene.node(tip).position;

		// A full cycle, in steps that do not divide the duration evenly, because
		// a wrap that only works on exact multiples is not a wrap.
		for (int i = 0; i < 7; i++) scene.step_animations(2.0f / 7.0f);

		Vec3 wrapped = scene.node(tip).position;
		test::@check(near(wrapped, first, 0.01f),
			"a full loop landed at (%.3f, %.3f, %.3f), expected (%.3f, %.3f, %.3f)",
			wrapped.x, wrapped.y, wrapped.z, first.x, first.y, first.z);
		test::@check(top_layer(scene, prop).playing, "a looping clip stopped itself");
	};
}

<*
 A clip that does not loop stops on its last frame.

 Not at its first. A character that finishes sitting down and springs back to
 standing is the animation bug everyone writes once, and it comes from a
 non-looping clip whose time was wrapped anyway or reset on completion.

 `is_animating` going false is the other half, and it is what `main.c3`'s sleep
 condition reads — a window that keeps redrawing a finished clip forever is the
 same bug wearing the opposite clothes.
*>
fn void a_finished_clip_stops_where_it_ended() @test
{
	@with_pass(; three::Renderer* renderer)
	{
		three::Scene* scene = renderer.pass.scene;

		three::AssetId id = renderer.pass.assets.load(&renderer.gpu, FIXTURE)!!;
		three::NodeId prop = scene.instantiate(id, scene.root, "prop");
		three::NodeId tip = named(scene, "tip");

		scene.play(prop, "slide", loop: false);
		test::@check(scene.is_animating(), "a clip that was just played is not animating");

		bool still = scene.step_animations(5.0f);
		test::@check(!still, "a finished non-looping clip reported that it was still playing");
		test::@check(!scene.is_animating(), "and is_animating still says yes");

		Vec3 ended = scene.node(tip).position;
		test::@check(near(ended, { 3, 0, 0 }),
			"a finished clip left `tip` at (%.3f, %.3f, %.3f), expected its last key (3, 0, 0)",
			ended.x, ended.y, ended.z);

		// And it stays there rather than drifting on a further step.
		scene.step_animations(5.0f);
		Vec3 held = scene.node(tip).position;
		test::@check(near(held, { 3, 0, 0 }), "a stopped clip moved again");
	};
}

<*
 Playing poses the instance immediately, before any frame is stepped.

 A prop placed and played in the same breath should look like its first frame.
 Without this it wears its rest pose for one frame — which for a character whose
 clip starts mid-stride is a visible snap on every spawn.

 `blink` is used because its first key differs from the file's own TRS: the
 fixture's `loose` node has scale 1 and the clip's first key is also 1, so
 instead this steps past the step and checks that the *stop* pose survived, which
 is the same guarantee from the other end. `slide` proves the first-frame case:
 `tip`'s file position and its first key agree, so the check that matters is that
 playing does not leave the node untouched.
*>
fn void playing_poses_the_instance_at_once() @test
{
	@with_pass(; three::Renderer* renderer)
	{
		three::Scene* scene = renderer.pass.scene;

		three::AssetId id = renderer.pass.assets.load(&renderer.gpu, FIXTURE)!!;
		three::NodeId prop = scene.instantiate(id, scene.root, "prop");
		three::NodeId loose = named(scene, "loose");

		// Move it somewhere the clip does not agree with, so "was it posed" has
		// an answer that is not also "was it left alone".
		scene.node(loose).scale = { 9, 9, 9 };

		scene.play(prop, "blink");
		Vec3 posed = scene.node(loose).scale;
		test::@check(near(posed, { 1, 1, 1 }),
			"play() left the node at (%.3f, %.3f, %.3f) instead of posing it at the clip's first key",
			posed.x, posed.y, posed.z);
	};
}

<*
 Stopping holds the pose rather than rewinding it.

 A character that stops mid-stride and snaps to a T-pose is what `stop()` is
 usually reached for to prevent.
*>
fn void stopping_holds_the_pose() @test
{
	@with_pass(; three::Renderer* renderer)
	{
		three::Scene* scene = renderer.pass.scene;

		three::AssetId id = renderer.pass.assets.load(&renderer.gpu, FIXTURE)!!;
		three::NodeId prop = scene.instantiate(id, scene.root, "prop");
		three::NodeId tip = named(scene, "tip");

		scene.play(prop, "slide");
		scene.step_animations(1.0f);
		Vec3 mid = scene.node(tip).position;

		test::@check(scene.stop(prop), "stop() found no player");
		test::@check(!scene.is_animating(), "a stopped clip still counts as animating");

		scene.step_animations(1.0f);
		Vec3 after = scene.node(tip).position;
		test::@check(near(after, mid), "stopping moved `tip` from (%.3f) to (%.3f)", mid.x, after.x);
	};
}

<*
 An animated prop still draws, and the drawn transform is the sampled one.

 Every check above reads a node. This one goes all the way through: the sampled
 transform has to reach the world matrix, the instance record and the frame.
 A sampler writing into a node that `update_world_matrices` never revisits —
 forgetting to mark it dirty — passes every other test in this file.
*>
fn void a_sampled_transform_reaches_the_frame() @test
{
	@with_pass(; three::Renderer* renderer)
	{
		three::Scene* scene = renderer.pass.scene;

		three::AssetId id = renderer.pass.assets.load(&renderer.gpu, FIXTURE)!!;
		three::NodeId prop = scene.instantiate(id, scene.root, "prop");
		three::NodeId tip = named(scene, "tip");

		scene.play(prop, "slide");
		scene.step_animations(1.0f);

		renderer.render_offscreen()!!;

		// `render_offscreen` runs the world-matrix walk, so a node the sampler
		// wrote to without marking dirty would still be at its file position.
		Vec3 drawn = scene.node(tip).world_position();
		test::@check(near(drawn, { 2, 0, -4 }),
			"after a frame `tip` is at (%.3f, %.3f, %.3f), expected (2, 0, -4) — the sample did not reach the walk",
			drawn.x, drawn.y, drawn.z);

		three::SceneStats stats = renderer.pass.stats();
		test::@check(stats.unique_meshes == 4, "an animated prop drew %d meshes", stats.unique_meshes);
	};
}

// ============================================================================
// Crossfading
// ============================================================================

<*
 The node called `name` under `root`, so two copies of one file can be told
 apart.

 `named` searches the whole scene and answers with the first match, which is what
 every check above wants and exactly what a test with two copies of `hierarchy.glb`
 in it cannot use — both copies have an `arm`.
*>
fn three::NodeId under(three::Scene* scene, three::NodeId root, String name)
{
	three::Node* node = scene.node(root);
	if (node == null) return three::NO_NODE;
	if (node.name == name) return root;

	foreach (child : node.children)
	{
		three::NodeId found = under(scene, child, name);
		if (found.is_set()) return found;
	}
	return three::NO_NODE;
}

<*
 How far a rotation turns, in radians.

 Through `acos` of the real part, clamped: a quaternion a float short of unit
 makes `acos` answer NaN, and a NaN compares false against every bound a check
 could put on it — so the test would pass by failing to fail.
*>
fn float turn_of(Quaternionf rotation)
{
	float real = rotation.l;
	if (real < -1) real = -1;
	if (real > 1) real = 1;
	return 2.0f * math::acos(real);
}

<*
 Half a crossfade is half the turn.

 `spin` takes `arm` from the identity to a quarter turn, and the clip being faded
 out of — `slide` — does not touch `arm` at all, so the fade starts from the
 identity. The slerp midpoint of an arc that starts at the identity is *exactly*
 half its angle, which makes this an equality rather than a shape somebody has to
 eyeball: a fade that snapped to the new clip a frame late would be at the full
 angle, and one that snapped early would be at zero.

 The reference copy plays `spin` outright and is stepped by the same call, so the
 angle being halved is the file's own number and not one written down here.
*>
fn void half_a_crossfade_is_half_the_turn() @test
{
	@with_pass(; three::Renderer* renderer)
	{
		three::Scene* scene = renderer.pass.scene;
		three::AssetId id = renderer.pass.assets.load(&renderer.gpu, FIXTURE)!!;

		three::NodeId reference = scene.instantiate(id, scene.root, "reference");
		three::NodeId faded = scene.instantiate(id, scene.root, "faded");
		three::NodeId reference_arm = under(scene, reference, "arm");
		three::NodeId faded_arm = under(scene, faded, "arm");

		test::@check(scene.play(faded, "slide"), "`slide` would not play");
		test::@check(scene.play(reference, "spin"), "the reference would not play `spin`");
		test::@check(scene.play(faded, "spin", fade: 1.0f), "`spin` would not fade in");

		// None of the incoming clip has arrived yet, so the arm is still where the
		// clip on its way out left it — and `slide` leaves it at the identity.
		float at_start = turn_of(scene.node(faded_arm).rotation);
		test::@check(at_start < 0.001f, "the fade starts at %f radians, expected 0", at_start);

		scene.step_animations(0.5f);

		float full = turn_of(scene.node(reference_arm).rotation);
		float half = turn_of(scene.node(faded_arm).rotation);
		test::@check(full > 0.1f, "the reference turned %f radians, so there is nothing to be half of", full);
		test::@check(
			math::abs(half - full * 0.5f) < 0.002f,
			"halfway through the fade the arm is at %f radians, expected half of %f", half, full
		);
	};
}

<*
 A finished fade lands exactly on the clip it was fading into.

 The other end of the check above, and the one that says the fade *stops*: a
 weight that never quite reaches one leaves a character permanently a few percent
 short of every pose it plays, which looks like a rig with soft joints rather than
 like a bug.
*>
fn void a_finished_fade_is_the_new_clip_exactly() @test
{
	@with_pass(; three::Renderer* renderer)
	{
		three::Scene* scene = renderer.pass.scene;
		three::AssetId id = renderer.pass.assets.load(&renderer.gpu, FIXTURE)!!;

		three::NodeId reference = scene.instantiate(id, scene.root, "reference");
		three::NodeId faded = scene.instantiate(id, scene.root, "faded");
		three::NodeId reference_arm = under(scene, reference, "arm");
		three::NodeId faded_arm = under(scene, faded, "arm");

		scene.play(faded, "slide");
		scene.play(reference, "spin");
		scene.play(faded, "spin", fade: 0.5f);

		// Past the end of the fade, not up to it: the frame the weight reaches one
		// on is the frame it has to be exact on.
		scene.step_animations(0.5f);
		scene.step_animations(0.25f);

		float want = turn_of(scene.node(reference_arm).rotation);
		float got = turn_of(scene.node(faded_arm).rotation);
		test::@check(
			math::abs(got - want) < 0.0001f,
			"after the fade the arm is at %f radians and the reference is at %f", got, want
		);
	};
}

<*
 The clip a fade is leaving goes on running while it leaves.

 A walk faded into a wave keeps walking for the length of the fade. Holding the
 outgoing clip on the frame it was on when the fade started would stop the legs a
 beat before the arms move, which reads as a hitch rather than as a transition —
 and it is the cheaper implementation, so it is the one to check against.

 `tip` is `slide`'s channel and `spin` never touches it, so `tip` is `slide`'s
 value at the weight `slide` has left over the rest pose for the weight it has
 lost. A quarter second into a one-second fade that is 0.75 of `slide` at 0.75 s
 (x = 1.75) and 0.25 of rest (x = 1): 1.5625 with a running clock, 1.375 with one
 held where the fade began.
*>
fn void the_clip_a_fade_leaves_goes_on_running() @test
{
	@with_pass(; three::Renderer* renderer)
	{
		three::Scene* scene = renderer.pass.scene;
		three::AssetId id = renderer.pass.assets.load(&renderer.gpu, FIXTURE)!!;

		three::NodeId prop = scene.instantiate(id, scene.root, "prop");
		three::NodeId tip = under(scene, prop, "tip");

		scene.play(prop, "slide");
		scene.step_animations(0.5f);

		scene.play(prop, "spin", fade: 1.0f);
		scene.step_animations(0.25f);
		float x = scene.node(tip).position.x;

		test::@check(math::abs(x - 1.5625f) < 0.001f,
			"`tip` is at %.4f a quarter into the fade, expected 1.5625 — 1.375 is the outgoing clip held still", x);
	};
}

<*
 Fading into the clip that is already playing does not restart it.

 **The call a locomotion state machine makes is `play(state.clip, { fade })` every
 time it runs.** Starting a fresh fade on each of those would hold the character
 at the start of a crossfade forever — a bug that looks like the animation system
 being broken rather than like the script asking for the wrong thing — so the
 clip carries on where it is, and restarting a clip outright is `play` without a
 fade. (It does take the speed: `a_redundant_fade_takes_the_speed`.)
*>
fn void fading_into_the_playing_clip_does_nothing() @test
{
	@with_pass(; three::Renderer* renderer)
	{
		three::Scene* scene = renderer.pass.scene;
		three::AssetId id = renderer.pass.assets.load(&renderer.gpu, FIXTURE)!!;

		three::NodeId prop = scene.instantiate(id, scene.root, "prop");
		three::NodeId tip = under(scene, prop, "tip");

		scene.play(prop, "slide");
		scene.step_animations(1.0f);
		Vec3 midway = scene.node(tip).position;

		test::@check(scene.play(prop, "slide", fade: 0.5f), "a redundant fade answered false");
		Vec3 after = scene.node(tip).position;
		test::@check(
			near(after, midway),
			"asking to fade into the playing clip moved `tip` from (%.3f) to (%.3f) — it restarted",
			midway.x, after.x
		);

		// And ten more of the same call leave it running rather than pinned.
		for (int i = 0; i < 10; i++)
		{
			scene.play(prop, "slide", fade: 0.5f);
			scene.step_animations(0.05f);
		}
		Vec3 still_going = scene.node(tip).position;
		test::@check(
			!near(still_going, after),
			"ten redundant fades pinned `tip` at (%.3f)", after.x
		);
	};
}

<*
 Fading into the playing clip takes its speed without restarting it.

 A walk whose cadence follows the ground speed is the same walk asked for every
 frame at a slightly different rate, so the redundant fade has to keep the clip
 where it is (the test above) *and* take the new rate — or the feet skate for as
 long as the walk lasts.

 `slide` is x = 1 + t on `tip`: half a second in is 1.5, and a quarter second at
 double speed after that is 2.0. A restart would have put it back at 1.
*>
fn void a_redundant_fade_takes_the_speed() @test
{
	@with_pass(; three::Renderer* renderer)
	{
		three::Scene* scene = renderer.pass.scene;
		three::AssetId id = renderer.pass.assets.load(&renderer.gpu, FIXTURE)!!;

		three::NodeId prop = scene.instantiate(id, scene.root, "prop");
		three::NodeId tip = under(scene, prop, "tip");

		scene.play(prop, "slide");
		scene.step_animations(0.5f);
		test::@check(math::abs(scene.node(tip).position.x - 1.5f) < 0.001f,
			"half a second into `slide`, `tip` is at %.3f, expected 1.5", scene.node(tip).position.x);

		scene.play(prop, "slide", speed: 2.0f, fade: 0.25f);
		test::@check(layer_of(renderer, prop, "slide").speed == 2.0f, "the redundant fade left the speed at %f",
			layer_of(renderer, prop, "slide").speed);
		test::@check(scene.player(prop).layer_count == 1, "the redundant fade added a second copy of the clip");

		scene.step_animations(0.25f);
		float x = scene.node(tip).position.x;
		test::@check(math::abs(x - 2.0f) < 0.001f,
			"a quarter second at double speed put `tip` at %.3f, expected 2.0", x);
	};
}

<*
 A one-shot that has run out fades out held, rather than snapping.

 The landing case: a jump played with `loop: false` finishes on its last frame,
 and the walk that follows has to blend out of that frame. It used to count as
 "nothing playing", which skipped the fade and put the new clip on at full weight
 in one frame.

 `spin` is the clip faded into and `slide` never touches `arm`, so half a second
 into a one-second fade the arm is at half the turn a copy playing `spin` outright
 reaches — the check `half_a_crossfade_is_half_the_turn` makes from a playing
 clip. A snap would be at the full turn. And the held pose has no clock: the
 time it is held at does not move while it fades.
*>
fn void a_finished_one_shot_fades_out_held() @test
{
	@with_pass(; three::Renderer* renderer)
	{
		three::Scene* scene = renderer.pass.scene;
		three::AssetId id = renderer.pass.assets.load(&renderer.gpu, FIXTURE)!!;

		three::NodeId reference = scene.instantiate(id, scene.root, "reference");
		three::NodeId prop = scene.instantiate(id, scene.root, "prop");
		three::NodeId reference_arm = under(scene, reference, "arm");
		three::NodeId arm = under(scene, prop, "arm");

		scene.play(prop, "slide", loop: false);
		scene.step_animations(2.5f);
		test::@check(!layer_of(renderer, prop, "slide").playing, "`slide` was still playing past its end");

		scene.play(reference, "spin");
		scene.play(prop, "spin", fade: 1.0f);
		three::AnimationLayer* held = layer_of(renderer, prop, "slide");
		test::@check(held != null && held.target == 0,
			"the finished one-shot left the stack instead of fading out of it");
		test::@check(!held.playing, "the held pose started its clock again");

		float at = held.time;
		scene.step_animations(0.5f);
		held = layer_of(renderer, prop, "slide");
		test::@check(held != null && held.time == at,
			"the held pose moved from %f during the fade", at);

		float full = turn_of(scene.node(reference_arm).rotation);
		float half = turn_of(scene.node(arm).rotation);
		test::@check(full > 0.1f, "the reference turned %f radians, so there is nothing to be half of", full);
		test::@check(math::abs(half - full * 0.5f) < 0.002f,
			"halfway out of the finished one-shot the arm is at %f radians, expected half of %f", half, full);
	};
}

<*
 A stopped clip fades out from where it stopped.

 `stop()` holds the pose, which is what a script reaches for to freeze a
 character — and the clip played after it should leave that pose rather than snap
 onto the new one. The same half-turn as above, and the same frozen clock.
*>
fn void a_stopped_pose_fades_out() @test
{
	@with_pass(; three::Renderer* renderer)
	{
		three::Scene* scene = renderer.pass.scene;
		three::AssetId id = renderer.pass.assets.load(&renderer.gpu, FIXTURE)!!;

		three::NodeId reference = scene.instantiate(id, scene.root, "reference");
		three::NodeId prop = scene.instantiate(id, scene.root, "prop");
		three::NodeId reference_arm = under(scene, reference, "arm");
		three::NodeId arm = under(scene, prop, "arm");
		three::NodeId tip = under(scene, prop, "tip");

		scene.play(prop, "slide");
		scene.step_animations(1.0f);
		scene.stop(prop);

		scene.play(reference, "spin");
		scene.play(prop, "spin", fade: 1.0f);
		test::@check(layer_of(renderer, prop, "slide") != null && layer_of(renderer, prop, "spin") != null,
			"the fade out of a stopped pose was skipped");

		scene.step_animations(0.5f);
		float full = turn_of(scene.node(reference_arm).rotation);
		float half = turn_of(scene.node(arm).rotation);
		test::@check(math::abs(half - full * 0.5f) < 0.002f,
			"halfway out of the stopped pose the arm is at %f radians, expected half of %f", half, full);

		// `slide` stopped a second in, at x = 2, and half way out of it `tip` is half
		// of that and half of its rest, 1. A stopped clip that went on stepping
		// would have carried it to 2.5 and the mix to 1.75.
		float x = scene.node(tip).position.x;
		test::@check(math::abs(x - 1.5f) < 0.001f,
			"half way out of the stopped pose `tip` is at %.3f, expected 1.5", x);
	};
}

<*
 Going back to the clip a fade is leaving turns the fade round.

 Walk, run, walk inside one fade is a tap of shift. A fresh fade from the run
 would drop the walk — still three quarters of the picture here — for a frame.
 Turned round, the clip asked for arrives from the weight it already had, on the
 clock it was already running: `skinning_test` checks the baked frames come out
 the same either side of the call, and this checks the clocks.
*>
fn void going_back_mid_fade_turns_the_fade_round() @test
{
	@with_pass(; three::Renderer* renderer)
	{
		three::Scene* scene = renderer.pass.scene;
		three::AssetId id = renderer.pass.assets.load(&renderer.gpu, FIXTURE)!!;

		three::NodeId prop = scene.instantiate(id, scene.root, "prop");
		three::NodeId tip = under(scene, prop, "tip");

		scene.play(prop, "slide");
		scene.step_animations(0.5f);
		scene.play(prop, "spin", fade: 1.0f);
		scene.step_animations(0.25f);

		float slide_time = layer_of(renderer, prop, "slide").time;
		float spin_time = layer_of(renderer, prop, "spin").time;

		test::@check(scene.play(prop, "slide", fade: 1.0f), "going back to `slide` answered false");
		three::AnimationLayer* slide = layer_of(renderer, prop, "slide");
		three::AnimationLayer* spin = layer_of(renderer, prop, "spin");
		test::@check(slide != null && spin != null, "the fade back dropped a clip instead of turning round");
		test::@check(math::abs(slide.weight - 0.75f) < 0.001f && slide.target == 1.0f && spin.target == 0,
			"`slide` had 0.75 of the picture and should rise from there: weight %f target %f, spin target %f",
			slide.weight, slide.target, spin.target);
		test::@check(slide.time == slide_time && spin.time == spin_time,
			"the clocks did not carry over: `slide` %f (was %f), `spin` %f (was %f)",
			slide.time, slide_time, spin.time, spin_time);

		// A quarter second later the fade is over and `slide` is all there is,
		// having run on underneath the whole time: 0.5 + 0.25 + 0.25 seconds in.
		scene.step_animations(0.25f);
		float x = scene.node(tip).position.x;
		test::@check(layer_of(renderer, prop, "spin") == null, "the turned fade did not finish on time");
		test::@check(math::abs(x - 2.0f) < 0.001f, "after the fade `tip` is at %.3f, expected 2", x);
	};
}

<*
 `sync` starts the new clip at the old one's phase, plus an offset in cycles.

 A walk faded into a run should land the run on the same step, and when the two
 loops start on opposite feet the offset is half a cycle. All three of the
 fixture's clips last two seconds, so a phase is half a time.
*>
fn void sync_starts_at_the_outgoing_phase() @test
{
	@with_pass(; three::Renderer* renderer)
	{
		three::Scene* scene = renderer.pass.scene;
		three::AssetId id = renderer.pass.assets.load(&renderer.gpu, FIXTURE)!!;

		three::NodeId prop = scene.instantiate(id, scene.root, "prop");

		scene.play(prop, "slide");
		scene.step_animations(0.5f);
		scene.play(prop, "spin", fade: 0.25f, sync: 0.5f);
		float started = layer_of(renderer, prop, "spin").time;
		test::@check(math::abs(started - 1.5f) < 0.001f,
			"a quarter cycle in, plus half a cycle, is 1.5 s; `spin` started at %f", started);

		// Past the end of a cycle, the phase wraps rather than running off it.
		scene.step_animations(0.25f);
		scene.play(prop, "slide", time: 1.9f, sync: 0.5f);
		float again = layer_of(renderer, prop, "slide").time;
		test::@check(math::abs(again - 0.75f) < 0.001f,
			"phase 0.875 plus 0.5 is 0.375 of a cycle, 0.75 s; `slide` started at %f", again);

		// With nothing to sync from, the time asked for is where it starts.
		three::NodeId fresh = scene.instantiate(id, scene.root, "fresh");
		scene.play(fresh, "spin", time: 0.3f, sync: 0.0f);
		float first = layer_of(renderer, fresh, "spin").time;
		test::@check(math::abs(first - 0.3f) < 0.001f,
			"a first play with sync started at %f, expected the 0.3 it asked for", first);
	};
}

// ============================================================================
// The layer stack
// ============================================================================

<*
 A third clip asked for mid-fade joins the stack instead of dropping one.

 With one clip and one fade, `blink` asked for half way from `slide` to `spin` had
 to throw one of them away, and whichever went showed as a pop. Now all three are
 on the stack: the call changes nothing on screen — `blink` enters at nothing —
 and from there the other two fall in proportion while it rises, so the weights
 keep summing to one and no frame shows the rest pose through the transition.
*>
fn void a_third_clip_mid_fade_does_not_pop() @test
{
	@with_pass(; three::Renderer* renderer)
	{
		three::Scene* scene = renderer.pass.scene;
		three::AssetId id = renderer.pass.assets.load(&renderer.gpu, FIXTURE)!!;

		three::NodeId prop = scene.instantiate(id, scene.root, "prop");
		three::NodeId tip = under(scene, prop, "tip");
		three::NodeId arm = under(scene, prop, "arm");

		scene.play(prop, "slide");
		scene.step_animations(0.5f);
		scene.play(prop, "spin", fade: 1.0f);
		scene.step_animations(0.25f);

		Vec3 tip_before = scene.node(tip).position;
		float turn_before = turn_of(scene.node(arm).rotation);

		scene.play(prop, "blink", fade: 1.0f);
		test::@check(scene.player(prop).layer_count == 3, "three clips asked for, %d on the stack",
			scene.player(prop).layer_count);
		test::@check(near(scene.node(tip).position, tip_before), "`tip` jumped from %.4f to %.4f",
			tip_before.x, scene.node(tip).position.x);
		test::@check(math::abs(turn_of(scene.node(arm).rotation) - turn_before) < 0.0001f,
			"the arm jumped from %f to %f radians", turn_before, turn_of(scene.node(arm).rotation));

		scene.step_animations(0.5f);
		float total = 0;
		three::AnimationPlayer* player = scene.player(prop);
		for (uint i = 0; i < player.layer_count; i++) total += player.layers[i].weight;
		test::@check(math::abs(total - 1.0f) < 0.0001f,
			"half way to `blink` the weights sum to %f — the rest pose is showing through", total);
		test::@check(math::abs(layer_of(renderer, prop, "blink").weight - 0.5f) < 0.0001f,
			"`blink` has %f of the picture half way, expected 0.5", layer_of(renderer, prop, "blink").weight);
	};
}

<*
 A node only the leaving clip drove goes back to rest when the clip is gone.

 `tip` is `slide`'s alone. The fade used to write the outgoing clip at full weight
 and mix the incoming one over it, so `tip` held `slide`'s last value through the
 fade and kept it for good afterwards — a live character's arm frozen in the pose
 of a clip that finished long ago, where the baked path put it back.
*>
fn void a_node_only_the_old_clip_drove_returns_to_rest() @test
{
	@with_pass(; three::Renderer* renderer)
	{
		three::Scene* scene = renderer.pass.scene;
		three::AssetId id = renderer.pass.assets.load(&renderer.gpu, FIXTURE)!!;

		three::NodeId prop = scene.instantiate(id, scene.root, "prop");
		three::NodeId tip = under(scene, prop, "tip");

		scene.play(prop, "slide");
		scene.step_animations(1.0f);
		test::@check(math::abs(scene.node(tip).position.x - 2.0f) < 0.001f, "`slide` did not reach x = 2");

		scene.play(prop, "spin", fade: 0.5f);
		scene.step_animations(0.6f);
		test::@check(layer_of(renderer, prop, "slide") == null, "`slide` is still on the stack after its fade");
		float x = scene.node(tip).position.x;
		test::@check(math::abs(x - 1.0f) < 0.001f, "`tip` stayed at %.3f, expected its rest at 1", x);
	};
}

<*
 `Scene.blend` holds the weights it was given, under the rest pose for the rest.

 A quarter of `slide` and three quarters of `spin`, summing to one. `tip` is
 `slide`'s alone, so it is a quarter of `slide`'s value and three quarters of its
 rest; `arm` is `spin`'s alone, so it is the normalised mix of three quarters of
 `spin`'s rotation and a quarter of the identity it rests at. And the weights are
 *held*: nothing fades them anywhere.
*>
fn void a_held_blend_holds_its_weights() @test
{
	@with_pass(; three::Renderer* renderer)
	{
		three::Scene* scene = renderer.pass.scene;
		three::AssetId id = renderer.pass.assets.load(&renderer.gpu, FIXTURE)!!;

		three::NodeId reference = scene.instantiate(id, scene.root, "reference");
		three::NodeId prop = scene.instantiate(id, scene.root, "prop");
		three::NodeId reference_arm = under(scene, reference, "arm");
		three::NodeId tip = under(scene, prop, "tip");
		three::NodeId arm = under(scene, prop, "arm");

		scene.play(prop, "slide");
		scene.step_animations(1.0f);

		String[2] clips = { "slide", "spin" };
		float[2] weights = { 0.25f, 0.75f };
		test::@check(scene.blend(prop, clips[..], weights[..]), "the blend was refused");
		scene.play(reference, "spin");

		// `slide` kept its clock at one second; a quarter of x = 2 over three
		// quarters of the rest at 1.
		float x = scene.node(tip).position.x;
		test::@check(math::abs(x - 1.25f) < 0.001f, "`tip` is at %.4f, expected 1.25", x);

		scene.step_animations(0.5f);
		x = scene.node(tip).position.x;
		test::@check(math::abs(x - 1.375f) < 0.001f, "half a second on `tip` is at %.4f, expected 1.375", x);

		Quaternionf spun = scene.node(reference_arm).rotation;
		Quaternionf identity = { 0, 0, 0, 1 };
		Quaternionf want = { .v = (identity.v * 0.25f + spun.v * 0.75f).normalize() };
		float got = turn_of(scene.node(arm).rotation);
		test::@check(math::abs(got - turn_of(want)) < 0.0005f,
			"the arm turned %f radians, expected three quarters of the way to `spin`'s %f: %f",
			got, turn_of(spun), turn_of(want));

		test::@check(layer_of(renderer, prop, "slide").weight == 0.25f && layer_of(renderer, prop, "spin").weight == 0.75f,
			"the held weights moved: slide %f spin %f",
			layer_of(renderer, prop, "slide").weight, layer_of(renderer, prop, "spin").weight);
	};
}

<*
 Phase-locked layers read their time off one shared cycle.

 What a walk and a run blended by speed need, or their feet drift apart: each
 locked clip is at `start + frac(phase + offset) · duration`, and the cycle
 advances at the weighted mean of the locked clips' own rates. The fixture's clips
 are all two seconds long, so half a second is a quarter of a cycle — `slide` at
 offset 0 reads 0.5 s, and `spin` half a cycle on reads 1.5 s.
*>
fn void synced_layers_share_a_phase() @test
{
	@with_pass(; three::Renderer* renderer)
	{
		three::Scene* scene = renderer.pass.scene;
		three::AssetId id = renderer.pass.assets.load(&renderer.gpu, FIXTURE)!!;
		three::NodeId prop = scene.instantiate(id, scene.root, "prop");

		String[2] clips = { "slide", "spin" };
		float[2] weights = { 0.5f, 0.5f };
		float[2] offsets = { 0.0f, 0.5f };
		test::@check(scene.blend(prop, clips[..], weights[..], offsets: offsets[..]), "the blend was refused");
		test::@check(scene.player(prop).phased, "a blend with offsets did not lock a phase");
		test::@check(math::abs(layer_of(renderer, prop, "spin").time - 1.0f) < 0.001f,
			"`spin` entered half a cycle on at %f, expected 1", layer_of(renderer, prop, "spin").time);

		scene.step_animations(0.5f);
		float slide = layer_of(renderer, prop, "slide").time;
		float spin = layer_of(renderer, prop, "spin").time;
		test::@check(math::abs(slide - 0.5f) < 0.001f && math::abs(spin - 1.5f) < 0.001f,
			"a quarter cycle on, `slide` is at %f (want 0.5) and `spin` at %f (want 1.5)", slide, spin);
	};
}

<*
 The stack holds four clips, and a fifth makes room by dropping the lightest.

 Two of the fixture's three clips are asked for twice — once held by a `stop()`
 and once fresh, which is a restart faded out of where the clip stopped and so a
 layer of its own — to fill the stack, and the one that leaves is the one that
 was the least of the picture.
*>
fn void the_stack_holds_four_and_drops_the_lightest() @test
{
	@with_pass(; three::Renderer* renderer)
	{
		three::Scene* scene = renderer.pass.scene;
		three::AssetId id = renderer.pass.assets.load(&renderer.gpu, FIXTURE)!!;
		three::NodeId prop = scene.instantiate(id, scene.root, "prop");

		scene.play(prop, "slide");
		scene.play(prop, "spin", fade: 1.0f);
		scene.step_animations(0.25f);
		scene.play(prop, "blink", fade: 1.0f);
		scene.step_animations(0.25f);
		scene.stop(prop);
		scene.play(prop, "slide", fade: 1.0f);
		scene.step_animations(0.1f);
		three::AnimationPlayer* player = scene.player(prop);
		test::@check(player.layer_count == 4, "four clips asked for, %d on the stack", player.layer_count);

		// The lightest as the fifth arrives, by what it has and where it is going —
		// after the stop, which holds every weight where it is.
		scene.stop(prop);
		uint lightest = 0;
		for (uint i = 1; i < player.layer_count; i++)
		{
			if (player.layers[i].weight + player.layers[i].target
				< player.layers[lightest].weight + player.layers[lightest].target) lightest = i;
		}
		three::AnimationLayer gone = player.layers[lightest];

		scene.play(prop, "spin", fade: 1.0f);
		player = scene.player(prop);
		test::@check(player.layer_count == 4, "a fifth clip left %d on the stack, expected four", player.layer_count);
		for (uint i = 0; i < player.layer_count; i++)
		{
			three::AnimationLayer* layer = &player.layers[i];
			test::@check(!(layer.clip == gone.clip && layer.weight == gone.weight && layer.time == gone.time),
				"the lightest layer (weight %f) is still on the stack", gone.weight);
		}
	};
}

<*
 A blend asked for every frame lets the clips it does not name go — all the way.

 A state machine calls `blend` every frame with the weights it wants, and a clip
 it stopped naming has to leave. Re-aimed every frame at what it has left over the
 fade, it covered the same fraction of the rest each time and never arrived: the
 layer stayed on the stack, at a weight too small to see and a cost too large to
 ignore, for as long as the blend went on being asked for.
*>
fn void a_blend_asked_every_frame_lets_a_clip_go() @test
{
	@with_pass(; three::Renderer* renderer)
	{
		three::Scene* scene = renderer.pass.scene;
		three::AssetId id = renderer.pass.assets.load(&renderer.gpu, FIXTURE)!!;
		three::NodeId prop = scene.instantiate(id, scene.root, "prop");

		scene.play(prop, "slide");
		String[1] clips = { "spin" };
		float[1] weights = { 1.0f };
		for (int frame = 0; frame < 30; frame++)
		{
			scene.blend(prop, clips[..], weights[..], fade: 0.25f);
			scene.step_animations(1.0f / 60.0f);
		}
		test::@check(layer_of(renderer, prop, "slide") == null,
			"half a second of blends with a quarter-second fade left `slide` on the stack at %f",
			layer_of(renderer, prop, "slide") == null ? 0.0f : layer_of(renderer, prop, "slide").weight);
		test::@check(scene.player(prop).layer_count == 1, "%d layers remain", scene.player(prop).layer_count);
	};
}
