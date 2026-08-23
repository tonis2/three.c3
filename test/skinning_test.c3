<*
 Skinning: the streams, the baked poses, and that the three paths agree.

	`c3c test --trust=full --test-noleak --test-filter three_tests::skinning`

 The fixture is `test/fixtures/skinned.glb`, written by
 `test/fixtures/make_skinned.py` — which explains every number in it and why the
 weights are hard-assigned rather than blended: the posed position of each vertex
 has to be one matrix multiply a test can do by hand, or the check is only this
 suite agreeing with itself.

 **What is worth asserting here is not "does it draw".** A skinned mesh that
 renders its bind pose forever renders perfectly, validates cleanly, and is
 completely broken; so is one that poses correctly and reads the palette of the
 instance next to it. The checks are built around numbers a person can verify
 from the fixture's documentation — the tip goes from (0.2, 2, 0) to (-1, 1.2, 0)
 at the end of `Bend` — and around the three paths producing the same picture,
 which is the property the whole design rests on.
*>
module three_tests::skinning;

import three;
import vk;
import image;
import gltf;
import std::core::test;
import std::io;
import std::math;
import std::math::vector;
import std::math::matrix;

const String FIXTURE = "test/fixtures/skinned.glb";

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

<*
 The file's skin is read, and it names the joints the file names.

 The cheap half of the parse and the one everything else indexes through: a skin
 whose joint list is empty or in the wrong order poses every vertex by the wrong
 bone, and the picture that produces is a mesh folded through itself rather than
 an error.
*>
fn void the_skin_is_read_from_the_file() @test
{
	@with_pass(; three::Renderer* renderer)
	{
		three::AssetId id = renderer.pass.assets.load(&renderer.gpu, FIXTURE)!!;
		three::Asset* asset = renderer.pass.assets.slot(id);
		test::@check(asset != null, "the fixture loads");
		if (asset == null) return;

		test::@check(asset.skins.len() == 1, "one skin, got %d", asset.skins.len());
		if (asset.skins.len() != 1) return;

		three::AssetSkin* skin = &asset.skins[0];
		test::@check(skin.joints.len() == 2, "two joints, got %d", skin.joints.len());
		if (skin.joints.len() != 2) return;

		// glTF node indices, in the skin's own order: Root is node 1 and Mid is
		// node 2. Not sorted by accident — this is the order JOINTS_0 indexes.
		test::@check(skin.joints[0] == 1, "joint 0 is node 1, got %d", skin.joints[0]);
		test::@check(skin.joints[1] == 2, "joint 1 is node 2, got %d", skin.joints[1]);
	};
}

<*
 The node that carries the mesh is the node that names the skin.

 glTF puts the skin on the node and the influences on the primitive, and a loader
 that reads one without the other has geometry it cannot pose or a skeleton
 nothing is attached to.
*>
fn void the_mesh_node_names_its_skin() @test
{
	@with_pass(; three::Renderer* renderer)
	{
		three::AssetId id = renderer.pass.assets.load(&renderer.gpu, FIXTURE)!!;
		three::Asset* asset = renderer.pass.assets.slot(id);
		if (asset == null) return;

		int found = -1;
		foreach (i, &node : asset.nodes)
		{
			if (node.skin >= 0) found = (int)i;
		}
		test::@check(found == 0, "node 0 carries the skin, got %d", found);
		if (found < 0) return;

		test::@check(asset.nodes[(sz)found].skin == 0, "and it is skin 0");
		test::@check(asset.nodes[(sz)found].mesh_count == 1, "and it draws one primitive");

		// Every other node is unskinned, including the joints themselves — a joint
		// is posed *by* the skin, it is not posed *with* one.
		foreach (i, &node : asset.nodes)
		{
			if ((int)i == found) continue;
			test::@check(node.skin == -1, "node %d should carry no skin, got %d", i, node.skin);
		}
	};
}

<*
 The influence streams reach the device, together.

 `has_skin` is both-or-neither by construction, and the check is here rather than
 left to the reading code because the failure it guards is silent: joints without
 weights poses every vertex by whatever floats happened to be at that address.
*>
fn void the_influence_streams_upload() @test
{
	@with_pass(; three::Renderer* renderer)
	{
		three::AssetId id = renderer.pass.assets.load(&renderer.gpu, FIXTURE)!!;
		// Loading describes; retaining uploads. Instantiating is what retains.
		three::NodeId root = renderer.pass.scene.instantiate(id);
		test::@check(root.is_set(), "the fixture instantiates");

		three::Asset* asset = renderer.pass.assets.slot(id);
		if (asset == null) return;

		uint skinned = 0;
		foreach (&mesh : asset.meshes)
		{
			if (!mesh.has_skin) continue;
			skinned++;
			test::@check(mesh.joints.buffer != null, "'%s' has a joints buffer", mesh.name);
			test::@check(mesh.weights.buffer != null, "'%s' has a weights buffer", mesh.name);
		}

		// The bar is skinned and the prop is not, which is the case a file with one
		// of each exists to cover: `has_skin` is per primitive, not per file.
		test::@check(skinned == 1, "one skinned mesh of %d, got %d", asset.meshes.len(), skinned);
	};
}

<*
 A `ubyte` JOINTS_0 arrives as the joint indices the file wrote.

 The fixture stores them narrow, which is what an exporter does for a rig this
 small, and the shader reads `uint4`. The widening happens on upload and a
 mistake in it is not a crash — it is joint 0 for every vertex, which poses the
 whole mesh by the root bone and looks like a rig that never got bound.

 Read back through the glTF stream rather than off the device, because the point
 is what the *file* said: the device copy is checked by the render tests, which
 cannot pass if this is wrong.
*>
fn void narrow_joint_indices_widen_correctly() @test
{
	gltf::GltfStream stream = gltf::open(FIXTURE, mem)!!;
	defer stream.close();
	// `open` parses the JSON and stops, exactly as `Assets.load` does; the buffer
	// an accessor points into is not mapped until something asks for it.
	stream.load_all_buffers()!!;

	gltf::Primitive primitive = stream.gltf.meshes[0].primitives[0];
	sz? attr = primitive.attributes.get("JOINTS_0");
	test::@check(@ok(attr), "the fixture's bar carries JOINTS_0");
	if (catch attr) return;

	test::@check(
		stream.gltf.accessors[attr].data_type == gltf::DataType.CHAR,
		"and stores it narrow, which is the case being covered"
	);

	uint[6] first;
	uint seen = 0;
	stream.@each_joint(primitive, 0; ushort[<4>] j, sz i)
	{
		if (i < 6) first[i] = (uint)j[0];
		seen++;
	};

	test::@check(seen == 6, "six vertices, got %d", seen);
	// Rows y=0 and y=1 ride joint 0; row y=2 rides joint 1.
	for (uint i = 0; i < 4; i++)
	{
		test::@check(first[i] == 0, "vertex %d rides joint 0, got %d", i, first[i]);
	}
	test::@check(first[4] == 1, "vertex 4 rides joint 1, got %d", first[4]);
	test::@check(first[5] == 1, "vertex 5 rides joint 1, got %d", first[5]);
}

// ============================================================================
// The bake
// ============================================================================

<*
 Bake the fixture and hand back the matrices, so a check can read them.

 The table is device-local a moment after `ensure_poses` returns, so this runs
 `Asset.bake_poses` a second time over the same asset — the same function the
 upload filled its staging copy with, over inputs that have not changed. What
 that cannot catch is a bad `vkCmdCopyBuffer`, and nothing here tries to: the
 render checks are where a table that did not reach the device shows up.
*>
macro @with_poses(; @body(three::Asset* asset, Matrix4f[] poses))
{
	@with_pass(; three::Renderer* renderer)
	{
		three::AssetId id = renderer.pass.assets.load(&renderer.gpu, FIXTURE)!!;
		// Instantiating retains, retaining uploads, and uploading a skinned mesh
		// bakes. Nothing here calls `ensure_poses` by hand, which is the point:
		// the trigger is part of what is being checked.
		renderer.pass.scene.instantiate(id);

		three::Asset* asset = renderer.pass.assets.slot(id);
		test::@check(asset != null, "the fixture loads");
		if (asset == null) return;
		test::@check(asset.poses.buffer != null, "and drawing it baked a pose buffer");
		test::@check(asset.pose_matrices > 0, "which holds %d matrices", asset.pose_matrices);
		if (asset.pose_matrices == 0) return;

		Matrix4f[] poses = mem::new_array(Matrix4f, (usz)asset.pose_matrices);
		defer free(poses);
		asset.bake_poses(poses);

		@body(asset, poses);
	};
}

// A point through a column-major matrix, spelled out the way `transform_aabb`
// spells it — translation at m[12..14].
fn Vec3 apply(Matrix4f m, Vec3 p)
{
	float[<16>] v = m.m;
	return {
		v[0] * p.x + v[4] * p.y + v[8] * p.z + v[12],
		v[1] * p.x + v[5] * p.y + v[9] * p.z + v[13],
		v[2] * p.x + v[6] * p.y + v[10] * p.z + v[14],
	};
}

fn bool near(float a, float b) => math::abs(a - b) < 1e-4f;

<*
 Every skin's rest segment is the identity, joint for joint.

 **The check the rest of the bake is built on.** A skin matrix is
 `joint_world * inverse_bind`, and at the bind pose those two are inverses of each
 other — so anything other than the identity here means the file's node transforms
 and its inverse bind matrices disagree, and every posed frame is wrong by exactly
 that much without ever looking wrong enough to suspect.

 It is also the check that catches a transposed read. glTF stores a MAT4
 column-major and so does `Matrix4f`; transpose the fixture's
 `translate(0, -1, 0)` and its -1 lands in the bottom row, where instead of
 cancelling the joint's translation it becomes a projective term — and the
 product stops being the identity in a way this sees immediately.
*>
fn void the_rest_pose_is_the_identity() @test
{
	@with_poses(; three::Asset* asset, Matrix4f[] poses)
	{
		Matrix4f identity = matrix::IDENTITY4{float};

		foreach (s, &skin : asset.skins)
		{
			for (uint j = 0; j < skin.joints.len(); j++)
			{
				Matrix4f rest = poses[skin.rest_offset + j];
				for (uint e = 0; e < 16; e++)
				{
					test::@check(
						near(rest.m[e], identity.m[e]),
						"skin %d joint %d element %d of the rest pose is %f, expected %f — the inverse bind matrices and the node transforms disagree",
						s, j, e, rest.m[e], identity.m[e]
					);
				}
			}
		}
	};
}

<*
 At the end of `Bend`, the tip lands where the fixture says it does.

 `make_skinned.py` works the arithmetic out in its docstring: the tip vertex
 (0.2, 2, 0) rides joint 1 with weight 1, and the joint's matrix at t=1 is
 `translate(0,1,0) · rotate_z(90°) · translate(0,-1,0)`, which walks the point to
 (-1, 1.2, 0).

 **A number from outside this code.** Every other way of checking a pose — bake
 it twice, compare against a second implementation, look at a picture — is this
 suite agreeing with itself. This one fails if the multiply order is reversed, if
 the hierarchy is composed the wrong way up, if the sample lands on the wrong
 frame, or if the rotation is read as a different quaternion convention.
*>
fn void a_bent_joint_puts_the_tip_where_the_maths_says() @test
{
	@with_poses(; three::Asset* asset, Matrix4f[] poses)
	{
		int bend = -1;
		foreach (i, &clip : asset.clips)
		{
			if (clip.name == "Bend") bend = (int)i;
		}
		test::@check(bend >= 0, "the fixture has a clip called Bend");
		if (bend < 0) return;

		three::BakedPose* segment = asset.segment(0, (uint)bend);
		test::@check(segment != null, "and it is baked for skin 0");
		if (segment == null) return;

		// One second at thirty frames a second, endpoint included.
		test::@check(segment.frame_count == 31, "31 frames, got %d", segment.frame_count);

		// The last frame is t = 1, where the quarter turn is complete.
		uint last = segment.frame_at((int)segment.frame_count - 1);
		Vec3 tip = apply(poses[last + 1], { 0.2, 2.0, 0.0 });

		test::@check(near(tip.x, -1.0f), "the tip's x is %f, expected -1", tip.x);
		test::@check(near(tip.y, 1.2f), "the tip's y is %f, expected 1.2", tip.y);
		test::@check(near(tip.z, 0.0f), "the tip's z is %f, expected 0", tip.z);

		// And the root joint has not moved: the clip drives Mid alone, so a bake
		// that leaked one joint's rotation into another would show here.
		Vec3 base = apply(poses[last], { 0.2, 0.0, 0.0 });
		test::@check(near(base.x, 0.2f) && near(base.y, 0.0f), "the root joint stayed put, got (%f, %f)", base.x, base.y);
	};
}

<*
 The frame at t=0 of a clip is the rest pose again.

 Both fixture clips start from the identity rotation, so their first frame has to
 come back to the same matrices segment zero holds. It catches an off-by-one in
 the frame-to-time arithmetic — sampling frame 0 at `1/fps` rather than at
 `start` — which is invisible in motion and is a character that never quite
 returns to its rest pose.
*>
fn void the_first_frame_of_a_clip_is_the_rest_pose() @test
{
	@with_poses(; three::Asset* asset, Matrix4f[] poses)
	{
		foreach (&segment : asset.baked)
		{
			three::AssetSkin* skin = &asset.skins[segment.skin];
			uint first = segment.frame_at(0);

			for (uint j = 0; j < segment.joint_count; j++)
			{
				Matrix4f rest = poses[skin.rest_offset + j];
				Matrix4f frame = poses[first + j];
				for (uint e = 0; e < 16; e++)
				{
					test::@check(
						near(rest.m[e], frame.m[e]),
						"clip %d joint %d element %d is %f at frame 0 and %f at rest",
						segment.clip, j, e, frame.m[e], rest.m[e]
					);
				}
			}
		}
	};
}

<*
 The segments tile the buffer without overlapping and without running off it.

 The fixture has two clips over one skin precisely so this has something to check:
 with one segment any offset arithmetic passes. An overlap is two clips writing
 each other's frames, which renders as a character that plays a blend of two
 animations nobody asked for.
*>
fn void the_baked_segments_do_not_overlap() @test
{
	@with_poses(; three::Asset* asset, Matrix4f[] poses)
	{
		test::@check(asset.baked.len() == 2, "two segments, got %d", asset.baked.len());

		// Rest poses come first and every segment sits above all of them.
		uint rest_end = 0;
		foreach (&skin : asset.skins) rest_end += (uint)skin.joints.len();

		foreach (i, &a : asset.baked)
		{
			uint a_start = a.frame_offset;
			uint a_end = a.frame_offset + a.frame_count * a.joint_count;

			test::@check(a_start >= rest_end, "segment %d starts at %d, inside the rest poses ending at %d", i, a_start, rest_end);
			test::@check(a_end <= asset.pose_matrices, "segment %d ends at %d, past the buffer's %d", i, a_end, asset.pose_matrices);

			foreach (j, &b : asset.baked)
			{
				if (j <= i) continue;
				uint b_start = b.frame_offset;
				uint b_end = b.frame_offset + b.frame_count * b.joint_count;
				test::@check(
					a_end <= b_start || b_end <= a_start,
					"segments %d [%d,%d) and %d [%d,%d) overlap",
					i, a_start, a_end, j, b_start, b_end
				);
			}
		}
	};
}

<*
 A posed character is culled against a box that contains the pose.

 `Bend` swings the tip to x = -1 and the bind pose reaches only to x = -0.2, so a
 skinned node culled against `mesh.bounds` would be dropped by a frustum the
 bent bar is plainly inside of. The bake has every joint matrix of every frame in
 hand, so the box costs a walk of numbers that already exist.
*>
fn void the_skinned_bounds_contain_the_bend() @test
{
	@with_poses(; three::Asset* asset, Matrix4f[] poses)
	{
		test::@check(
			asset.skinned_bounds.min.x <= -1.0f + 1e-3f,
			"the skinned box reaches x = %f, and Bend takes the tip to -1",
			asset.skinned_bounds.min.x
		);
		test::@check(
			asset.skinned_bounds.min.x <= asset.bounds.min.x,
			"and it is no smaller than the bind pose's box"
		);
	};
}

// ============================================================================
// Placing a character
// ============================================================================

<*
 A character instantiates as its meshes and none of its bones.

 The fixture is four glTF nodes — the skinned mesh, two joints, and a prop
 parented to the second joint. `Root` holds `Mid` which holds the prop, so
 neither joint is prunable and the default instantiation is all four.

 What it does prove is the rule's shape rather than its arithmetic: nothing is
 dropped that something hangs off. The count that would change is checked from
 the other side in `a_bare_skeleton_is_pruned`.
*>
fn void a_prop_on_a_bone_keeps_its_chain() @test
{
	@with_pass(; three::Renderer* renderer)
	{
		three::AssetId id = renderer.pass.assets.load(&renderer.gpu, FIXTURE)!!;
		three::NodeId root = renderer.pass.scene.instantiate(id);

		int prop = find_named(&renderer.pass.scene, root, "Prop");
		test::@check(prop >= 0, "the prop survives a default instantiation");

		// And the joint holding it, because otherwise the prop would be parented to
		// the character's root and would not follow the hand at all.
		int mid = find_named(&renderer.pass.scene, root, "Mid");
		test::@check(mid >= 0, "and so does the joint it hangs off");
	};
}

<*
 A joint with nothing under it is not made into a node.

 The fixture's `Mid` holds a prop, so pruning it would orphan geometry — but
 `Root` holds only `Mid`, and if the prop were gone both would go. Checked by
 counting what a `skeleton: true` instantiation produces against what the default
 one does: the difference is the bones, and on this file the default keeps them
 only because of the prop.

 **This is the number the crowd case rests on.** A sixty-bone character has to
 instantiate as two nodes and not sixty-two, or a hundred of them is six thousand
 nodes and the per-frame cost the baked buffer exists to remove comes back as a
 scene-graph walk.
*>
fn void the_skeleton_flag_decides_what_exists() @test
{
	@with_pass(; three::Renderer* renderer)
	{
		three::AssetId id = renderer.pass.assets.load(&renderer.gpu, FIXTURE)!!;

		three::NodeId lean = renderer.pass.scene.instantiate(id);
		uint without = count_subtree(&renderer.pass.scene, lean);

		three::NodeId full = renderer.pass.scene.instantiate(id, name: "", skeleton: true);
		uint with = count_subtree(&renderer.pass.scene, full);

		test::@check(with >= without, "keeping the skeleton produces at least as many nodes (%d vs %d)", with, without);

		// The skinned mesh is a child of the group with an identity transform
		// whichever way it was instantiated: glTF ignores a skinned mesh node's own
		// transform, and saying that in the graph is what leaves `Instance.model`
		// with no special case.
		int character = find_named(&renderer.pass.scene, lean, "Character");
		test::@check(character >= 0, "the character node exists");
		if (character < 0) return;

		three::Node* node = renderer.pass.scene.node(node_at(&renderer.pass.scene, lean, "Character"));
		if (node == null) return;
		test::@check(node.parent == lean, "and it sits directly under the group it was instantiated as");
		test::@check(node.skin == 0, "and it names skin 0, got %d", node.skin);
	};
}

<*
 A skinned node starts at its skin's rest pose, not at offset zero by accident.

 Zero happens to *be* the first skin's rest offset, so a file with one skin cannot
 tell the two apart — the check is that the offset is the skin's own, which is the
 form that stays true when a second skin is added.
*>
fn void an_unplayed_character_points_at_its_rest_pose() @test
{
	@with_pass(; three::Renderer* renderer)
	{
		three::AssetId id = renderer.pass.assets.load(&renderer.gpu, FIXTURE)!!;
		three::NodeId root = renderer.pass.scene.instantiate(id);

		three::Asset* asset = renderer.pass.assets.slot(id);
		if (asset == null || asset.skins.len() == 0) return;

		three::Node* node = renderer.pass.scene.node(node_at(&renderer.pass.scene, root, "Character"));
		test::@check(node != null, "the character node exists");
		if (node == null) return;

		test::@check(
			node.pose == asset.skins[0].rest_offset,
			"a fresh character sits at its rest offset %d, got %d",
			asset.skins[0].rest_offset, node.pose
		);
	};
}

// ---- subtree helpers -------------------------------------------------------

fn three::NodeId node_at(three::Scene* scene, three::NodeId root, String name)
{
	three::Node* node = scene.node(root);
	if (node == null) return three::NO_NODE;
	if (node.name == name) return root;

	foreach (child : node.children)
	{
		three::NodeId found = node_at(scene, child, name);
		if (found.is_set()) return found;
	}
	return three::NO_NODE;
}

fn int find_named(three::Scene* scene, three::NodeId root, String name)
{
	return node_at(scene, root, name).is_set() ? 1 : -1;
}

fn uint count_subtree(three::Scene* scene, three::NodeId root)
{
	three::Node* node = scene.node(root);
	if (node == null) return 0;
	uint total = 1;
	foreach (child : node.children) total += count_subtree(scene, child);
	return total;
}

// ============================================================================
// What reaches the screen
// ============================================================================

// Where the drawn pixels are, as a column range and a count. Enough to say "the
// silhouette moved left" without the test having to know the projection.
struct Silhouette
{
	uint drawn;
	int leftmost;
	int rightmost;
}

fn Silhouette measure(image::Image* shot, float[4] clear)
{
	char[3] background = {
		(char)(uint)(clear[0] * 255.0 + 0.5),
		(char)(uint)(clear[1] * 255.0 + 0.5),
		(char)(uint)(clear[2] * 255.0 + 0.5),
	};

	Silhouette out = { .drawn = 0, .leftmost = (int)W, .rightmost = -1 };
	for (uint y = 0; y < H; y++)
	{
		for (uint x = 0; x < W; x++)
		{
			sz i = (sz)(y * W + x) * 4;
			int dr = (int)shot.pixels[i] - (int)background[0];
			int dg = (int)shot.pixels[i + 1] - (int)background[1];
			int db = (int)shot.pixels[i + 2] - (int)background[2];
			if (dr * dr + dg * dg + db * db <= 12) continue;

			out.drawn++;
			if ((int)x < out.leftmost) out.leftmost = (int)x;
			if ((int)x > out.rightmost) out.rightmost = (int)x;
		}
	}
	return out;
}

<*
 A posed character draws in a different place from an unposed one.

 **The check that the whole chain is connected**, and the reason it is worth
 having on top of the arithmetic ones above: a bake that is perfect, an offset
 that is correct and a shader that never reads either of them renders a mesh in
 its bind pose, validates cleanly, and looks exactly like a character whose
 animation has not started yet.

 `Bend` takes the top of the bar from x = +0.2 to x = -1, so the silhouette has to
 extend further left after the pose is keyed. Measured as a column range rather
 than against named pixels because the projection is the camera's business and
 this check is about the geometry moving, not about where the frame is.
*>
fn void a_keyed_pose_moves_what_is_drawn() @test
{
	@with_pass(; three::Renderer* renderer)
	{
		three::AssetId id = renderer.pass.assets.load(&renderer.gpu, FIXTURE)!!;
		three::NodeId root = renderer.pass.scene.instantiate(id);
		// Fitted once, before either capture, so the two frames share a camera and
		// the comparison is about the mesh rather than about the fit. The fit uses
		// the skinned bounds, so it is the same box in both.
		renderer.pass.frame_camera();

		image::Image rest_shot = renderer.capture()!!;
		Silhouette rest = measure(&rest_shot, renderer.clear);
		rest_shot.free();

		test::@check(rest.drawn > 0, "the bind pose rasterises something");

		// The end of the clip, where the quarter turn is complete. Not looping, so
		// the phase is not wrapped back to the start.
		bool played = renderer.pass.scene.play(root, "Bend", loop: false, speed: 1.0f, time: 1.0f);
		test::@check(played, "the fixture's Bend clip plays");

		image::Image bent_shot = renderer.capture()!!;
		Silhouette bent = measure(&bent_shot, renderer.clear);
		bent_shot.free();

		test::@check(bent.drawn > 0, "and the posed character rasterises something too");
		test::@check(
			bent.leftmost < rest.leftmost,
			"the bend reaches further left than the bind pose: posed %d, rest %d — if these are equal the pose never reached the shader",
			bent.leftmost, rest.leftmost
		);
	};
}

<*
 A hundred characters at a hundred phases are one draw call.

 **The thesis of the whole design, stated as a number.** Every copy keys a
 different frame of one baked clip, and the only thing they disagree about is
 `Instance.pose` — which is per instance, so the bucket does not split. If this
 ever reports more than the two draws the fixture's two meshes need, the pose has
 stopped being per-instance data and a crowd has become a hundred draw calls.
*>
fn void a_crowd_at_different_phases_is_one_draw_call() @test
{
	@with_pass(; three::Renderer* renderer)
	{
		three::AssetId id = renderer.pass.assets.load(&renderer.gpu, FIXTURE)!!;

		const uint COPIES = 100;
		three::NodeId[COPIES] roots;
		for (uint i = 0; i < COPIES; i++)
		{
			roots[i] = renderer.pass.scene.instantiate(id);
			three::Node* node = renderer.pass.scene.node(roots[i]);
			if (node != null)
			{
				node.position = { (float)i * 2.0f, 0, 0 };
				node.dirty = true;
			}
			// Spread across the clip: copy i starts i/COPIES of the way in.
			renderer.pass.scene.play(roots[i], "Bend", loop: true, speed: 1.0f, time: (float)i / (float)COPIES);
		}

		renderer.pass.frame_camera();
		image::Image shot = renderer.capture()!!;
		defer shot.free();

		three::SceneStats stats = renderer.pass.stats();
		// Two meshes in the file — the bar and the prop — so two buckets, whatever
		// the copy count is.
		test::@check(
			stats.draw_calls == 2,
			"a hundred characters are %d draw calls, expected 2",
			stats.draw_calls
		);
		test::@check(
			stats.instances >= COPIES,
			"and %d instances, expected at least %d",
			stats.instances, COPIES
		);

		// And they are genuinely at different phases: identical offsets would be
		// one pose drawn a hundred times, which would also pass the count above.
		uint phases = 0;
		uint[COPIES] seen;
		for (uint i = 0; i < COPIES; i++)
		{
			three::NodeId character = node_at(&renderer.pass.scene, roots[i], "Character");
			three::Node* node = renderer.pass.scene.node(character);
			if (node == null) continue;

			bool already = false;
			for (uint j = 0; j < phases; j++)
			{
				if (seen[j] == node.pose) { already = true; break; }
			}
			if (!already) seen[phases++] = node.pose;
		}
		test::@check(phases > 10, "the copies key %d distinct frames, expected many", phases);
	};
}

// ============================================================================
// The live palette
// ============================================================================

<*
 Writing a bone node moves the skin — and only for the character that has one.

 **What `skeleton: true` is for.** A baked character's pose is a table lookup, so
 nothing a script does to a bone can reach it; a live character's palette is
 computed from those very nodes every frame, which is what makes a look-at, an
 aim offset or a foot planted on a slope expressible at all.

 The check is a rotation applied by hand to `Mid` — the same joint `Bend` drives —
 with no clip playing at all, so the only thing that can have moved the mesh is
 the bone. The baked copy in the same scene is the control: it sees the same
 frame and must not move, which is what proves the two paths are actually
 separate rather than one path with a flag on it.
*>
fn void writing_a_bone_moves_a_live_skin() @test
{
	@with_pass(; three::Renderer* renderer)
	{
		three::AssetId id = renderer.pass.assets.load(&renderer.gpu, FIXTURE)!!;

		three::NodeId live = renderer.pass.scene.instantiate(id, name: "", skeleton: true);
		renderer.pass.frame_camera();

		image::Image before_shot = renderer.capture()!!;
		Silhouette before = measure(&before_shot, renderer.clear);
		before_shot.free();
		test::@check(before.drawn > 0, "the live character rasterises at rest");

		// A quarter turn about +Z on the joint the clip would have driven. Nothing
		// is playing: this is a script moving a bone.
		three::NodeId mid = node_at(&renderer.pass.scene, live, "Mid");
		test::@check(mid.is_set(), "skeleton: true materialised the joint");
		if (!mid.is_set()) return;

		three::Node* bone = renderer.pass.scene.node(mid);
		if (bone == null) return;
		float half = (float)math::PI / 4.0f;
		bone.rotation = { 0, 0, math::sin(half), math::cos(half) };
		bone.dirty = true;

		image::Image after_shot = renderer.capture()!!;
		Silhouette after = measure(&after_shot, renderer.clear);
		after_shot.free();

		test::@check(
			after.leftmost < before.leftmost,
			"turning the bone swung the mesh left: %d against %d — if these match the live palette never reached the shader",
			after.leftmost, before.leftmost
		);
	};
}

<*
 A baked character ignores a bone somebody moved.

 The other half of the check above, and the one that would catch the two paths
 quietly becoming one: a default instantiation has no bone nodes at all, so there
 is nothing to move — and if pruning ever stopped happening, this says so by the
 mesh moving when it should not have.
*>
fn void writing_a_bone_does_not_move_a_baked_skin() @test
{
	@with_pass(; three::Renderer* renderer)
	{
		three::AssetId id = renderer.pass.assets.load(&renderer.gpu, FIXTURE)!!;
		three::NodeId baked = renderer.pass.scene.instantiate(id);
		renderer.pass.frame_camera();

		image::Image before_shot = renderer.capture()!!;
		Silhouette before = measure(&before_shot, renderer.clear);
		before_shot.free();

		three::NodeId mid = node_at(&renderer.pass.scene, baked, "Mid");
		if (mid.is_set())
		{
			three::Node* bone = renderer.pass.scene.node(mid);
			if (bone != null)
			{
				float half = (float)math::PI / 4.0f;
				bone.rotation = { 0, 0, math::sin(half), math::cos(half) };
				bone.dirty = true;
			}
		}

		image::Image after_shot = renderer.capture()!!;
		Silhouette after = measure(&after_shot, renderer.clear);
		after_shot.free();

		// The prop hangs off that joint and *does* move with it — it is an ordinary
		// node, not a skinned one — so the silhouette may change a little. What must
		// not happen is the bar swinging out to where the bent pose reaches.
		test::@check(
			after.leftmost >= before.leftmost - 4,
			"a baked character's mesh stayed put: leftmost went %d -> %d",
			before.leftmost, after.leftmost
		);
	};
}

<*
 A live character and a baked one share a bucket.

 **The property the one-bit selector exists for.** The palette a copy reads is
 chosen per instance, so a hero and the crowd behind him are one
 `vkCmdDrawIndexed` — where a palette pointer in the draw record would have split
 them into two, which is the design this replaced.
*>
fn void a_live_and_a_baked_character_share_a_draw_call() @test
{
	@with_pass(; three::Renderer* renderer)
	{
		three::AssetId id = renderer.pass.assets.load(&renderer.gpu, FIXTURE)!!;

		renderer.pass.scene.instantiate(id, name: "", skeleton: true);
		for (uint i = 0; i < 8; i++)
		{
			three::NodeId copy = renderer.pass.scene.instantiate(id);
			renderer.pass.scene.play(copy, "Bend", loop: true, speed: 1.0f, time: (float)i * 0.1f);
		}

		renderer.pass.frame_camera();
		image::Image shot = renderer.capture()!!;
		defer shot.free();

		three::SceneStats stats = renderer.pass.stats();
		test::@check(
			stats.draw_calls == 2,
			"one live character and eight baked ones are %d draw calls, expected 2",
			stats.draw_calls
		);
	};
}

// ============================================================================
// Compute skinning
// ============================================================================

<*
 The three paths draw the same character the same way.

 **The check the whole design rests on.** A baked instance keys a frame out of a
 device-local table; a live one reads a palette computed this frame from its bone
 nodes; a compute-routed one has its vertices posed by a dispatch before the
 render pass begins. Three entirely different routes through the renderer, and
 the only acceptable outcome is that they are indistinguishable on screen.

 Each is rendered alone, at the same pose, through the same camera, and the
 silhouettes are compared. Pixel-exact is not the bar — the three paths do the
 same arithmetic in a different order and float addition is not associative — so
 the comparison is the drawn area and the column range, which is what would move
 if a path posed the mesh differently rather than merely rounding differently.
*>
fn void the_three_paths_agree() @test
{
	Silhouette baked;
	Silhouette live;
	Silhouette computed;

	// One camera for all three, fitted to the same asset so the projection is
	// identical — the fit uses the asset's skinned bounds, which do not depend on
	// which path posed it.
	@with_pass(; three::Renderer* renderer)
	{
		three::AssetId id = renderer.pass.assets.load(&renderer.gpu, FIXTURE)!!;
		three::NodeId root = renderer.pass.scene.instantiate(id);
		renderer.pass.frame_camera();
		renderer.pass.scene.play(root, "Bend", loop: false, speed: 1.0f, time: 1.0f);

		image::Image shot = renderer.capture()!!;
		baked = measure(&shot, renderer.clear);
		shot.free();
	};

	@with_pass(; three::Renderer* renderer)
	{
		three::AssetId id = renderer.pass.assets.load(&renderer.gpu, FIXTURE)!!;
		three::NodeId root = renderer.pass.scene.instantiate(id, name: "", skeleton: true);
		renderer.pass.frame_camera();
		renderer.pass.scene.play(root, "Bend", loop: false, speed: 1.0f, time: 1.0f);

		image::Image shot = renderer.capture()!!;
		live = measure(&shot, renderer.clear);
		shot.free();
	};

	@with_pass(; three::Renderer* renderer)
	{
		three::AssetId id = renderer.pass.assets.load(&renderer.gpu, FIXTURE)!!;
		three::NodeId root = renderer.pass.scene.instantiate(id, name: "", compute_skin: true);
		renderer.pass.frame_camera();
		renderer.pass.scene.play(root, "Bend", loop: false, speed: 1.0f, time: 1.0f);

		image::Image shot = renderer.capture()!!;
		computed = measure(&shot, renderer.clear);
		shot.free();
	};

	test::@check(baked.drawn > 0, "the baked path draws something");
	test::@check(live.drawn > 0, "the live path draws something");
	test::@check(computed.drawn > 0, "the compute path draws something");

	// The live path samples at the exact time and the baked one snaps to the
	// nearest of thirty frames a second, so at t = 1.0 — which is exactly a baked
	// frame — they should land on the same pose. A few pixels of tolerance for the
	// arithmetic being done in a different order.
	test::@check(
		math::abs((int)baked.drawn - (int)live.drawn) < 40,
		"baked drew %d pixels and live drew %d",
		baked.drawn, live.drawn
	);
	test::@check(
		baked.leftmost == live.leftmost && baked.rightmost == live.rightmost,
		"baked spans columns %d..%d and live spans %d..%d",
		baked.leftmost, baked.rightmost, live.leftmost, live.rightmost
	);

	// The compute path does the identical blend, only earlier and through memory,
	// so it has less excuse than the other two to differ at all.
	test::@check(
		math::abs((int)baked.drawn - (int)computed.drawn) < 40,
		"baked drew %d pixels and compute drew %d",
		baked.drawn, computed.drawn
	);
	test::@check(
		baked.leftmost == computed.leftmost && baked.rightmost == computed.rightmost,
		"baked spans columns %d..%d and compute spans %d..%d",
		baked.leftmost, baked.rightmost, computed.leftmost, computed.rightmost
	);
}

<*
 A compute-routed character costs a draw call of its own.

 Stated as a check because it is the flag's price and the kind of thing that is
 easy to forget: pre-skinned vertices come out of a different buffer, so a copy
 routed through compute cannot share a `DrawRecord` — or a draw — with one that is
 not. If this ever reports the same count as an unrouted scene, the bucket has
 stopped splitting and one of the two groups is reading the other's geometry.
*>
fn void a_compute_routed_character_splits_the_bucket() @test
{
	@with_pass(; three::Renderer* renderer)
	{
		three::AssetId id = renderer.pass.assets.load(&renderer.gpu, FIXTURE)!!;

		for (uint i = 0; i < 4; i++) renderer.pass.scene.instantiate(id);
		renderer.pass.frame_camera();

		image::Image plain = renderer.capture()!!;
		plain.free();
		uint before = renderer.pass.stats().draw_calls;

		renderer.pass.scene.instantiate(id, name: "", compute_skin: true);
		image::Image mixed = renderer.capture()!!;
		mixed.free();
		uint after = renderer.pass.stats().draw_calls;

		test::@check(
			after == before + 1,
			"routing one copy through compute went from %d draw calls to %d, expected one more",
			before, after
		);

		// **And the dispatch really happened.** Without this the suite has a hole
		// wide enough to drive through: if `skin` bailed out early, every bucket
		// would fall back to `FLAG_HAS_SKIN`, the vertex shader would pose the mesh
		// exactly as it always does, and both the split above and
		// `the_three_paths_agree` would pass while no compute shader had ever run.
		// The pipeline is built lazily, on the first frame that needs it, so its
		// existence is the evidence.
		test::@check(
			renderer.pass.skin_pipeline.ready,
			"the compute pipeline was built, which is what proves the dispatch ran at all"
		);
	};
}

<*
 A scene with no compute-routed character builds no compute pipeline.

 The other half of the check above, and the reason the path is lazy: a project
 that never asks for compute skinning should not read `shaders/skin.slang` off
 disk, hand it to Slang, or hold a `VkPipeline` for it.
*>
fn void the_compute_pipeline_is_not_built_unless_asked() @test
{
	@with_pass(; three::Renderer* renderer)
	{
		three::AssetId id = renderer.pass.assets.load(&renderer.gpu, FIXTURE)!!;
		three::NodeId root = renderer.pass.scene.instantiate(id);
		renderer.pass.frame_camera();
		renderer.pass.scene.play(root, "Bend", loop: true);

		image::Image shot = renderer.capture()!!;
		shot.free();

		test::@check(
			!renderer.pass.skin_pipeline.ready,
			"an ordinary skinned character built a compute pipeline it never uses"
		);
	};
}

macro @with_validating_pass(; @body(three::Renderer* renderer))
{
	// `sync: true` is what makes this check about the barrier rather than only
	// about the dispatch's arguments — see `create_instance`.
	vk::Instance instance = three::create_instance(true, headless: true, sync: true)!!;
	defer instance.free();

	three::Renderer renderer;
	renderer.init(instance, (vk::SurfaceKHR)null, W, H, validate: true)!!;
	defer renderer.free();

	renderer.pass.init(&renderer.gpu, &renderer.target)!!;

	@body(&renderer);
}

<*
 The compute dispatch is well formed under the validation layer.

 What this covers: the push range against the compute pipeline's layout, the
 dispatch's own arguments, the pipeline bind point, and the buffer lifetimes
 across a reallocation that happens mid-scene. None of those are visible to a
 pixel check, and all of them are things the layer reports.

 **What it does not cover, measured rather than assumed: the barrier.** Deleting
 the `COMPUTE_SHADER -> VERTEX_SHADER` barrier at the end of `MeshPass.skin`
 leaves this test green — with the ordinary layer, and also with synchronization
 validation requested through `create_instance(sync: true)` and
 `VK_EXT_validation_features` enabled. This machine's layer does not report a
 read-after-write hazard on a storage buffer, so the barrier's correctness rests
 on the specification and on review, not on this check. Said out loud because a
 test named for something it does not do is worse than no test: if this file ever
 runs somewhere the hazard *is* reported, the injection above is the thing to
 repeat.

 All three paths are exercised in one command stream, plus a frame with a
 compute-routed character appearing after one that had none — which is the case
 that grows the output buffer mid-scene and reallocates it while a previous
 frame's fence has only just been waited on.

 Skipped when the Khronos layer is not installed, like the other checks in this
 project that need it.
*>
fn void the_skinning_paths_are_silent_under_validation() @test
{
	@with_validating_pass(; three::Renderer* renderer)
	{
		if (!renderer.gpu.validation) return;

		three::AssetId id = renderer.pass.assets.load(&renderer.gpu, FIXTURE)!!;

		// A baked character first, and one frame before the sink is armed, so that
		// anything the layer objects to afterwards belongs to skinning rather than
		// to the setup.
		three::NodeId baked = renderer.pass.scene.instantiate(id);
		renderer.pass.scene.play(baked, "Bend", loop: true);
		renderer.pass.frame_camera();

		image::Image warmup = renderer.capture()!!;
		warmup.free();

		renderer.gpu.begin_capture();

		// A live character joins, then a compute-routed one — so the output buffer
		// is allocated on a frame that already had drawing in it.
		three::NodeId live = renderer.pass.scene.instantiate(id, name: "", skeleton: true);
		renderer.pass.scene.play(live, "Bend", loop: true);
		image::Image one = renderer.capture()!!;
		one.free();

		three::NodeId computed = renderer.pass.scene.instantiate(id, name: "", compute_skin: true);
		renderer.pass.scene.play(computed, "Bend", loop: true);
		image::Image two = renderer.capture()!!;
		two.free();

		// A second compute-routed character, which grows the output buffer and
		// frees the previous one — the path the frames-in-flight rule governs.
		three::NodeId also = renderer.pass.scene.instantiate(id, name: "", compute_skin: true);
		renderer.pass.scene.play(also, "Twist", loop: true);
		image::Image three_ = renderer.capture()!!;
		three_.free();

		// The other frame path, for the reason `the_post_pass_is_silent_under_validation`
		// reaches for it: "they all go through one function" is a claim worth
		// checking rather than repeating.
		renderer.render_offscreen()!!;

		String errors = renderer.gpu.sink.errors.str_view();
		String warnings = renderer.gpu.sink.warnings.str_view();
		renderer.gpu.end_capture();

		test::@check(errors.len == 0, "skinning produced validation errors: %s", errors);
		test::@check(warnings.len == 0, "skinning produced validation warnings: %s", warnings);
	};
}

// ============================================================================
// From a script, which is the interface that matters
// ============================================================================

macro @with_js(; @body(three::JsRuntime* run))
{
	vk::Instance instance = three::create_instance(false, headless: true)!!;
	defer instance.free();

	three::Renderer renderer;
	renderer.init(instance, (vk::SurfaceKHR)null, W, H)!!;
	defer renderer.free();

	renderer.pass.init(&renderer.gpu, &renderer.target)!!;

	three::JsRuntime runtime;
	runtime.open(&renderer.pass, &renderer)!!;
	defer runtime.close();

	@body(&runtime);
}

<*
 A character instantiated from a script is skinned.

 **The path that is easy to leave broken**, and the reason this test exists
 separately from all the others: `Scene.instantiate` builds its own nodes and sets
 their skin as it goes, but `asset.instantiate()` in JavaScript hands back
 descriptions that become host nodes later, through the ordinary `add`. Nothing
 in that path would know a mesh was skinned unless `Object3D._materialize` says
 so — so every check above could pass with the whole script interface drawing
 bind poses.

 Asserted on the draw-call count and on the pose offset actually moving, because
 both are things only a working host-side skin produces.
*>
fn void a_script_can_animate_a_character() @test
{
	@with_js(; three::JsRuntime* run)
	{
		three::RunResult result = run.run(`
			const scene = new three.Scene();
			const asset = await three.load('test/fixtures/skinned.glb');
			const crowd = [];
			for (let i = 0; i < 12; i++) {
				const c = asset.instantiate();
				scene.add(c);
				c.position.set(i * 2, 0, 0);
				c.play('Bend', { loop: true, time: i / 12 });
				crowd.push(c);
			}
			three.camera.frameAll();
			return three.stats().drawCalls;
		`);
		defer result.free();

		test::@check(result.ok, "the script ran: %s", result.error);
		// Two meshes in the file, twelve copies of each, one draw call apiece.
		test::@check(result.value == "2", "twelve scripted characters are 2 draw calls, got '%s'", result.value);
	};
}

<*
 `skeleton: true` from a script gives bones that move the skin.

 The script-side twin of `writing_a_bone_moves_a_live_skin`: the option has to
 reach `Assets.flatten` for the bones to exist at all, and `_bindAnimation` has to
 run before anything plays for the palette to be computed from them.
*>
fn void a_script_can_pose_a_bone() @test
{
	@with_js(; three::JsRuntime* run)
	{
		three::RunResult result = run.run(`
			const scene = new three.Scene();
			const asset = await three.load('test/fixtures/skinned.glb');
			const hero = asset.instantiate(undefined, { skeleton: true });
			scene.add(hero);

			let bone = null;
			const walk = (o) => { if (o.name === 'Mid') bone = o; o.children.forEach(walk); };
			walk(hero);
			if (!bone) return 'no bone';

			bone.rotation.z = Math.PI / 2;
			three.camera.frameAll();
			three.render();
			return 'posed';
		`);
		defer result.free();

		test::@check(result.ok, "the script ran: %s", result.error);
		test::@check(result.value == "\"posed\"", "the skeleton materialised, got '%s'", result.value);
	};
}

// ============================================================================
// What it costs, reported
// ============================================================================

<*
 `stats()` tells the truth about what skinning cost.

 `plan.md` §3/S3 asked for this before any of the code existed, and asked for it
 pointing the other way: it assumed a live palette and warned that reporting a
 skinned bucket like an instanced one would hide a per-frame upload. This design
 has no per-frame upload for a baked character, so the hidden cost is now the
 pose memory — uploaded once, held for the life of the asset, and invisible in
 every other number `stats()` reports.

 **The check is that they are not zero and not nonsense**, because the failure
 this guards is a number that is wrong rather than a picture that is: an agent
 reading `poseBytes: 0` off a scene of rigged characters would conclude that
 rigging is free and build the level that proves otherwise.
*>
fn void stats_reports_what_skinning_cost() @test
{
	@with_pass(; three::Renderer* renderer)
	{
		three::AssetId id = renderer.pass.assets.load(&renderer.gpu, FIXTURE)!!;

		three::SceneStats empty = renderer.pass.stats();
		test::@check(empty.pose_bytes == 0, "an empty scene holds no pose memory, got %d", empty.pose_bytes);

		for (uint i = 0; i < 5; i++) renderer.pass.scene.instantiate(id);
		renderer.pass.scene.instantiate(id, name: "", compute_skin: true);

		three::SceneStats stats = renderer.pass.stats();

		// One skinned mesh in the file, and the compute-routed copy splits it, so
		// two of the buckets are skinned and the prop's is not.
		test::@check(stats.skinned_draws == 2, "%d skinned draws, expected 2", stats.skinned_draws);
		test::@check(stats.skinned_instances == 6, "%d skinned copies, expected 6", stats.skinned_instances);
		test::@check(
			stats.preskinned_instances == 1,
			"%d compute-routed copies, expected 1 — the expensive path is called out separately",
			stats.preskinned_instances
		);

		// Exactly what the bake allocated: two skins' worth of rest pose plus two
		// clips, shared by all six copies rather than counted per copy.
		three::Asset* asset = renderer.pass.assets.slot(id);
		if (asset == null) return;
		test::@check(
			stats.pose_bytes == (usz)asset.pose_matrices * Matrix4f::size,
			"poseBytes is %d and the bake allocated %d matrices",
			stats.pose_bytes, asset.pose_matrices
		);
		test::@check(stats.pose_bytes > 0, "and it is not zero, which is the number that would mislead");
	};
}
