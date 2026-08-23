<*
 Baking a rigged asset's clips into joint matrices, once, for the GPU to key
 into.

 `plan.md` §3. The milestone anticipated a **live palette** — every skinned
 instance's joint matrices recomputed and uploaded every frame, which it costed
 at ~192 KB a frame for fifty characters. This is the other design, and the
 difference is what a hundred characters cost:

 - A clip is sampled at a fixed rate **once**, at the moment the first skinned
   mesh of the file uploads, and the result is a device-local buffer that never
   changes again.
 - An instance names a frame with **one `uint`** — `Instance.pose`, an offset in
   matrices. A hundred zombies mid-stride at a hundred different phases disagree
   about that number and about nothing else, so they stay one bucket and one
   `vkCmdDrawIndexed`, and the per-frame cost of the crowd is a hundred integers.

 So the trade is memory against per-frame work, and the memory is small: sixty
 joints at thirty frames a second is 115 KB per second of clip, and a character
 with ten clips of animation is a megabyte that is uploaded once.

 **It also cannot tear.** `gpu/buffer.c3` records that "crig's pose palette tore
 for exactly this reason" — a host-visible buffer rewritten while the GPU was
 still reading last frame's copy. A baked table is written before anything draws
 and read for the life of the asset, so the failure is not mitigated here, it is
 absent.

 ## What it gives up, and where that is answered

 Quantised time, no blending between clips, and no way to move a bone. All three
 are the same limitation seen from different sides: the pose is a table lookup, so
 nothing can influence it that was not sampled at bake time. `MeshPass` writes a
 **live** palette into the same shader contract for characters instantiated with
 a skeleton, and `Instance.pose`'s top bit is which of the two buffers a copy
 reads — so the two kinds of character can share a draw call, and a script that
 needs a look-at asks for the expensive one by name.

 ## The rest pose is not a special case

 Every skin's segment zero is its bind pose, baked like any other frame, and a
 skinned node starts pointing at it. So a character that has never played
 anything draws correctly with no branch anywhere in the shader and no "is
 something playing" question in the draw loop — and the check that segment is
 exactly the identity is what proves the inverse bind matrices and the node
 transforms agree, which every other number here is built on.
*>
module three;

import std::math;
import std::math::matrix;
import std::math::vector;
import std::math::quaternion;
import std::collections::list;
import collision;
import gltf;
import vk;

<*
 Where one clip's frames sit in an asset's pose buffer.

 `frame_offset` and `joint_count` are both in matrices, so frame `f` of this
 segment starts at `frame_offset + f * joint_count` — which is the whole of the
 arithmetic that reaches an instance.

 `frame_count` includes the endpoint at `t = duration`, so a one-second clip at
 thirty frames a second is thirty-one frames and not thirty. Dropping it would
 make a looping clip skip from the frame before the end back to the start,
 which reads as a hitch once per loop and is the kind of thing that gets blamed
 on the animation.
*>
struct BakedPose
{
	uint skin;
	uint clip;
	uint frame_offset;
	uint frame_count;
	uint joint_count;
	float fps;
}

<*
 How finely a clip is sampled.

 Thirty is what the reference implementation this was modelled on uses, and it is
 the rate at which the quantisation stops being visible on ordinary locomotion.
 It is a constant rather than a parameter because the memory it decides is
 per asset and the number that would want tuning — a slow, close-up performance
 that shows the stepping — is better answered by the live palette than by baking
 the whole file finer.
*>
const float BAKE_FPS = 30.0;

// One node's transform while a frame is being posed. The three channels have to
// be carried separately rather than as a matrix, because a clip may drive one of
// them and leave the other two at the file's own values.
struct PosedNode @local
{
	Vec3 position;
	Quaternionf rotation;
	Vec3 scale;
}

<*
 Bake every clip of every skin of an asset into one device-local buffer.

 Called from `Assets.ensure_uploaded` the first time a skinned primitive of the
 file reaches the device, so a file that describes a skeleton and never draws it
 bakes nothing — G3/S3's rule, one level up from where `ensure_clip` applies it.

 **Every clip at once, rather than one at a time.** Baking lazily per clip would
 mean growing a device-local buffer, which is a copy command and a barrier or a
 CPU mirror of the whole table; and a character's clips *are* the character —
 nobody ships a walk cycle they do not intend to play. So the first play of
 anything pays for all of it, once, and every offset handed out afterwards stays
 valid for the life of the asset.

 Failure is not fatal to the asset. A skin whose inverse bind accessor will not
 read leaves the buffer unbuilt, every skinned node keeps `pose == 0`, and the
 mesh draws its bind pose — which is the same answer `ensure_uploaded` gives for
 a primitive that would not upload.
*>
fn void? Assets.ensure_poses(&self, Gpu* gpu, AssetId id)
{
	Asset* asset = self.slot(id);
	if (asset == null) return;
	// Built once. The buffer is immutable, so its existence is the memo.
	if (asset.poses.buffer != null) return;
	if (asset.skins.len() == 0 || asset.nodes.len() == 0) return;
	if (!asset.has_stream) return;

	foreach (i, &skin : asset.skins)
	{
		read_inverse_binds(asset, (uint)i);
		if (!skin.loaded) return;
	}

	// The curves, for every clip. `ensure_clip` is the memo and is idempotent, so
	// a clip somebody already played is not read twice.
	for (uint clip = 0; clip < asset.clips.len(); clip++)
	{
		self.ensure_clip(id, clip);
	}

	uint total = plan_segments(asset);
	if (total == 0) return;

	Matrix4f[] poses = mem::new_array(Matrix4f, (usz)total);
	defer free(poses);

	asset.bake_poses(poses);

	asset.poses = gpu.upload_stream(poses.ptr, Matrix4f::size * (sz)total)!;
	asset.pose_matrices = total;
	measure_skinned_bounds(asset, poses);
}

<*
 Read one skin's inverse bind matrices, and the bind matrices that undo them.

 **No transpose.** glTF stores a MAT4 column-major and C3's `Matrix4f` is
 column-major — `to_matrix` in gltf.c3l puts the translation at m[12..14] and
 `Node.world_position` reads it back from there — so the accessor's bytes are the
 matrix. `gltf.c3l`'s `@build_skin_matrixes` transposes twice on the way through,
 which is right for a consumer that wants row-major and is not this one.

 That is a claim worth a check rather than a comment, and it has one:
 `the_rest_pose_is_the_identity` fails on a transposed read, because a
 transposed `translate(0, -1, 0)` puts its -1 in the bottom row where it becomes
 a projective term instead of cancelling the joint's own translation.

 A skin with no accessor gets identity matrices, which is what the specification
 says an absent `inverseBindMatrices` means: the mesh is already in each joint's
 space.
*>
fn void read_inverse_binds(Asset* asset, uint index) @local
{
	AssetSkin* skin = &asset.skins[index];
	if (skin.loaded) return;

	sz count = skin.joints.len();
	skin.inverse_bind.init(mem, count);
	skin.bind.init(mem, count);

	if (index >= asset.stream.gltf.skins.len())
	{
		skin.loaded = true;
		return;
	}

	gltf::Skin source = asset.stream.gltf.skins[index];
	bool has_matrices = source.inverseBindAccessor < asset.stream.gltf.accessors.len();
	if (has_matrices)
	{
		if (catch asset.stream.load_skin_buffers(index)) has_matrices = false;
	}

	for (sz i = 0; i < count; i++)
	{
		Matrix4f inverse_bind = matrix::IDENTITY4{float};
		if (has_matrices)
		{
			gltf::Accessor accessor = asset.stream.gltf.accessors[source.inverseBindAccessor];
			if (i < accessor.count) inverse_bind = asset.stream.@cast_buffer(accessor, i, Matrix4f);
		}
		skin.inverse_bind.push(inverse_bind);
		skin.bind.push(invert(inverse_bind));
	}

	skin.loaded = true;
}

<*
 Decide where every segment goes, and return how many matrices the buffer needs.

 Rest poses first, all of them, so that a skin's rest offset is small and stable
 and does not move when a clip is added. Then one segment per (skin, clip): a
 clip is baked per skin because a joint matrix is only meaningful against the
 inverse bind pose it was folded through, so two skins playing one clip are two
 different sets of matrices.
*>
fn uint plan_segments(Asset* asset) @local
{
	uint offset = 0;

	foreach (&skin : asset.skins)
	{
		skin.rest_offset = offset;
		offset += (uint)skin.joints.len();
	}

	asset.baked.init(mem, asset.skins.len() * (asset.clips.len() + 1));

	foreach (s, &skin : asset.skins)
	{
		uint joint_count = (uint)skin.joints.len();
		if (joint_count == 0) continue;

		foreach (c, &clip : asset.clips)
		{
			uint frames = frame_count_of(clip.duration);
			asset.baked.push({
				.skin = (uint)s,
				.clip = (uint)c,
				.frame_offset = offset,
				.frame_count = frames,
				.joint_count = joint_count,
				.fps = BAKE_FPS,
			});
			offset += frames * joint_count;
		}
	}

	return offset;
}

<*
 How many frames a clip of this length bakes to, endpoint included.

 A zero-length clip — a pose rather than an animation, which is a legal thing for
 a file to contain — is one frame, not zero: a segment with no frames is an offset
 nothing can key, and the instance keying it would read whatever sat there.
*>
fn uint frame_count_of(float duration) @local
{
	if (duration <= 0) return 1;
	return (uint)math::ceil((double)duration * (double)BAKE_FPS) + 1;
}

<*
 Fill the planned buffer: every rest pose, then every frame of every segment.

 **Public, and that is for the tests.** What matters about a bake is the numbers
 in it, and they are on the device a moment after this returns — checking them
 through a picture would mean a render test for every arithmetic mistake, and a
 readback would mean a staging buffer built for nothing else. So the function
 that fills the array is callable with an array of the caller's own, and
 `the_rest_pose_is_the_identity` and `a_bent_joint_puts_the_tip_where_the_maths_says`
 run it over the same inputs the upload ran it over.

 Deterministic in both directions: same asset, same output, which is what makes
 that a check rather than a coincidence.

 @param poses : `At least Asset.pose_matrices long, which plan_segments decided.`
*>
fn void Asset.bake_poses(&self, Matrix4f[] poses)
{
	Asset* asset = self;
	sz nodes = asset.nodes.len();
	PosedNode[] scratch = mem::new_array(PosedNode, nodes);
	Matrix4f[] locals = mem::new_array(Matrix4f, nodes);
	Matrix4f[] world = mem::new_array(Matrix4f, nodes);
	defer
	{
		free(scratch);
		free(locals);
		free(world);
	}

	// The rest poses. `null` for the clip means "the file's own node transforms",
	// which is the bind pose, so every matrix here should come out the identity —
	// see `the_rest_pose_is_the_identity`.
	pose_at(asset, null, 0, scratch, locals, world);
	foreach (&skin : asset.skins)
	{
		write_joints(asset, skin, world, poses[skin.rest_offset..]);
	}

	foreach (&segment : asset.baked)
	{
		AssetSkin* skin = &asset.skins[segment.skin];
		AnimationClip* clip = &asset.clips[segment.clip];

		for (uint frame = 0; frame < segment.frame_count; frame++)
		{
			// The clip's own numbers: glTF times are absolute and need not start at
			// zero, so a frame is measured from `start` rather than from zero.
			float time = clip.start + (float)frame / segment.fps;
			pose_at(asset, clip, time, scratch, locals, world);

			usz at = (usz)segment.frame_offset + (usz)frame * (usz)segment.joint_count;
			write_joints(asset, skin, world, poses[at..]);
		}
	}
}

<*
 Put the asset's nodes into the pose a clip holds at `time`, and compose their
 world matrices.

 The same two halves `AnimationPlayer` runs per frame on the live scene graph,
 done here on the asset's own copy of the hierarchy — which is why nothing about
 baking needs a `Scene`, and why a hundred instances share one bake.

 `clip` may be null, which means the file's own transforms: the bind pose.
*>
fn void pose_at(
	Asset* asset,
	AnimationClip* clip,
	float time,
	PosedNode[] scratch,
	Matrix4f[] locals,
	Matrix4f[] world
) @local
{
	foreach (i, &node : asset.nodes)
	{
		scratch[i] = { .position = node.position, .rotation = node.rotation, .scale = node.scale };
	}

	if (clip != null)
	{
		float[4] value;
		foreach (&channel : clip.channels)
		{
			if (channel.node >= scratch.len) continue;
			channel.sample(time, value[..]);

			switch (channel.path)
			{
				case AnimatedPath.TRANSLATION:
					scratch[channel.node].position = { value[0], value[1], value[2] };
				case AnimatedPath.ROTATION:
					scratch[channel.node].rotation = { value[0], value[1], value[2], value[3] };
				case AnimatedPath.SCALE:
					scratch[channel.node].scale = { value[0], value[1], value[2] };
			}
		}
	}

	foreach (i, &node : scratch)
	{
		locals[i] = matrix::IDENTITY4{float}
			.translate(node.position)
			.mul(node.rotation.to_matrix())
			.scale(node.scale);
	}

	foreach (root : asset.roots)
	{
		compose_from(asset, root, matrix::IDENTITY4{float}, locals, world);
	}
}

<*
 One node's world matrix and every descendant's.

 Recursive for `flatten_node`'s reason: a glTF hierarchy is a rig, its depth is
 single digits in every file that exists, and a cycle is not expressible because
 `record_nodes` derives roots from "nothing claims it".
*>
fn void compose_from(Asset* asset, uint index, Matrix4f parent, Matrix4f[] locals, Matrix4f[] world) @local
{
	if (index >= world.len) return;
	world[index] = parent.mul(locals[index]);
	foreach (child : asset.nodes[index].children)
	{
		compose_from(asset, child, world[index], locals, world);
	}
}

<*
 One skin's joint matrices for a pose that has already been composed.

 `world * inverse_bind` and in that order: the inverse bind takes a vertex out of
 the mesh's bind pose and into the joint's own space, and the world matrix then
 puts it wherever that joint has moved to. Reversing them is the mistake that
 produces a mesh turned inside out around its own root rather than a posed one.
*>
fn void write_joints(Asset* asset, AssetSkin* skin, Matrix4f[] world, Matrix4f[] out) @local
{
	foreach (j, node : skin.joints)
	{
		if (j >= out.len) return;
		// A joint naming a node the file does not have poses nothing rather than
		// reading past the hierarchy — the vertices riding it stay where the bind
		// pose left them, which is visible and local instead of catastrophic.
		out[j] = node < world.len
			? world[node].mul(skin.inverse_bind[j])
			: matrix::IDENTITY4{float};
	}
}

<*
 The box every baked frame of this asset fits inside.

 The asset's bind-pose bounds transformed by each joint matrix of each frame, and
 unioned. Conservative — a joint that moves a hand does not move the whole box —
 and that is the right direction to be wrong in: too big keeps a draw the frustum
 could have skipped, too small drops a character the camera can see.

 The alternative, an exact bound, is a pass over every vertex of every frame, and
 buys back a handful of draw calls in exchange for the bake becoming the slow part
 of loading a character.
*>
fn void measure_skinned_bounds(Asset* asset, Matrix4f[] poses) @local
{
	collision::Aabb3 bind = asset.bounds;
	bool first = true;

	foreach (pose : poses)
	{
		collision::Aabb3 moved = transform_aabb(pose, bind);
		if (first)
		{
			asset.skinned_bounds = moved;
			first = false;
			continue;
		}
		asset.skinned_bounds = {
			.min = {
				math::min(asset.skinned_bounds.min.x, moved.min.x),
				math::min(asset.skinned_bounds.min.y, moved.min.y),
				math::min(asset.skinned_bounds.min.z, moved.min.z),
			},
			.max = {
				math::max(asset.skinned_bounds.max.x, moved.max.x),
				math::max(asset.skinned_bounds.max.y, moved.max.y),
				math::max(asset.skinned_bounds.max.z, moved.max.z),
			},
		};
	}

	if (first) asset.skinned_bounds = bind;
}

<*
 Which baked segment plays a clip on a skin, or null.

 Linear over a list that is `skins * clips` long — single digits times single
 digits in every file — and called on `play`, not per frame: the player keeps the
 segment it found.
*>
fn BakedPose* Asset.segment(&self, uint skin, uint clip)
{
	foreach (&segment : self.baked)
	{
		if (segment.skin == skin && segment.clip == clip) return segment;
	}
	return null;
}

<*
 The matrix offset of one frame of a segment, clamped to the segment.

 Clamping rather than wrapping: the caller has already decided what a time past
 the end means — a loop wrapped it, a one-shot stopped on it — and a second
 opinion here would silently disagree with whichever one was right.
*>
fn uint BakedPose.frame_at(&self, int frame)
{
	if (frame < 0) frame = 0;
	if (frame >= (int)self.frame_count) frame = (int)self.frame_count - 1;
	return self.frame_offset + (uint)frame * self.joint_count;
}
