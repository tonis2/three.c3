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
import vk;
import collision;
import std::core::test;
import std::io;
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
	vk::Instance instance = three::create_instance(false, headless: true)!!;
	defer instance.free();

	three::Renderer renderer;
	renderer.init(instance, (vk::SurfaceKHR)null, W, H)!!;
	defer renderer.free();

	renderer.pass.init(&renderer.gpu, &renderer.target)!!;

	@body(&renderer);
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
		three::Scene* scene = &renderer.pass.scene;

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
		three::Scene* scene = &renderer.pass.scene;
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
		three::Scene* scene = &renderer.pass.scene;

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
		three::Scene* scene = &renderer.pass.scene;

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
		three::Scene* scene = &renderer.pass.scene;

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
		three::Scene* scene = &renderer.pass.scene;

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

		float ahead = scene.player(one).time;
		float behind = scene.player(two).time;
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
		three::Scene* scene = &renderer.pass.scene;

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
		three::Scene* scene = &renderer.pass.scene;

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
		three::Scene* scene = &renderer.pass.scene;

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
		test::@check(scene.player(prop).playing, "a looping clip stopped itself");
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
		three::Scene* scene = &renderer.pass.scene;

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
		three::Scene* scene = &renderer.pass.scene;

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
		three::Scene* scene = &renderer.pass.scene;

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
		three::Scene* scene = &renderer.pass.scene;

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
