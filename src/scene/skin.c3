<*
 Baking a rigged asset's clips into joint matrices, once, for the GPU to key
 into.

 The obvious alternative is a live palette: every skinned instance's joint
 matrices recomputed and uploaded every frame, about 192 KB a frame for fifty
 characters. This does the opposite:

 - A clip is sampled at a fixed rate once, when the first skinned mesh of the
   file uploads, into a device-local buffer that never changes again.
 - An instance names a frame with one `uint` — `Instance.pose`, an offset in
   matrices. A hundred zombies mid-stride at a hundred different phases disagree
   about that number and nothing else, so they stay one bucket and one
   `vkCmdDrawIndexed`, and the crowd costs a hundred integers a frame.

 The trade is memory against per-frame work, and the memory is small: sixty
 joints at thirty frames a second is 115 KB per second of clip, so a character
 with ten clips is a megabyte uploaded once.

 It also cannot tear. A host-visible palette rewritten while the GPU is still
 reading last frame's copy is the classic failure here; a baked table is written
 before anything draws and read for the life of the asset.

 ## What it gives up

 Quantised time, no blending between clips, and no way to move a bone — all the
 same limitation from different sides: the pose is a table lookup, so nothing can
 influence it that was not sampled at bake time. `MeshPass` writes a *live*
 palette into the same shader contract for characters instantiated with a
 skeleton, and `Instance.pose`'s top bit says which of the two buffers a copy
 reads, so the two kinds of character still share a draw call and a script that
 needs a look-at asks for the expensive one by name.

 ## The rest pose is not a special case

 Every skin's segment zero is its bind pose, baked like any other frame, and a
 skinned node starts pointing at it. So a character that has never played
 anything draws correctly with no branch in the shader and no "is something
 playing" question in the draw loop — and checking that segment is exactly the
 identity is what proves the inverse bind matrices and the node transforms agree.
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
 segment starts at `frame_offset + f * joint_count`.

 `frame_count` includes the endpoint at `t = duration`, so a one-second clip at
 thirty frames a second is thirty-one frames and not thirty. Dropping it makes a
 looping clip skip from the frame before the end back to the start, which reads
 as a hitch once per loop and gets blamed on the animation.
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

 Thirty is the rate at which the quantisation stops being visible on ordinary
 locomotion. A constant rather than a parameter because the memory it decides is
 per asset, and the case that would want tuning — a slow, close-up performance
 that shows the stepping — is better answered by the live palette than by baking
 the whole file finer.
*>
const float BAKE_FPS = 30.0;

// One node's transform while a frame is being posed. The three channels are
// carried separately rather than as a matrix, because a clip may drive one of
// them and leave the other two at the file's own values.
struct PosedNode @local
{
	Vec3 position;
	Quaternionf rotation;
	Vec3 scale;
}

<*
 Bakes every clip of every skin of an asset into one device-local buffer.

 Called from `Assets.ensure_uploaded` the first time a skinned primitive of the
 file reaches the device, so a file that describes a skeleton and never draws it
 bakes nothing.

 Every clip at once rather than one at a time. Baking lazily per clip would mean
 growing a device-local buffer — a copy command and a barrier, or a CPU mirror of
 the whole table — and a character's clips *are* the character: nobody ships a
 walk cycle they do not intend to play. So the first play of anything pays for
 all of it once, and every offset handed out afterwards stays valid for the life
 of the asset.

 Failure is not fatal to the asset. A skin whose inverse bind accessor will not
 read leaves the buffer unbuilt, every skinned node keeps `pose == 0`, and the
 mesh draws its bind pose.
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
 Reads one skin's inverse bind matrices, and the bind matrices that undo them.

 No transpose. glTF stores a MAT4 column-major and C3's `Matrix4f` is
 column-major — `to_matrix` in gltf.c3l puts the translation at m[12..14] and
 `Node.world_position` reads it back from there — so the accessor's bytes are the
 matrix. `gltf.c3l`'s `@build_skin_matrixes` transposes twice on the way through,
 which is right for a consumer that wants row-major and is not this one.

 `the_rest_pose_is_the_identity` fails on a transposed read: a transposed
 `translate(0, -1, 0)` puts its -1 in the bottom row, where it becomes a
 projective term instead of cancelling the joint's own translation.

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
 Decides where every segment goes, and returns how many matrices the buffer
 needs.

 Rest poses first, all of them, so a skin's rest offset is small and stable and
 does not move when a clip is added. Then one segment per (skin, clip): a clip is
 baked per skin because a joint matrix is only meaningful against the inverse
 bind pose it was folded through, so two skins playing one clip are two different
 sets of matrices.
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

 A zero-length clip — a pose rather than an animation, which a file may legally
 contain — is one frame, not zero: a segment with no frames is an offset nothing
 can key, and the instance keying it would read whatever sat there.
*>
fn uint frame_count_of(float duration) @local
{
	if (duration <= 0) return 1;
	return (uint)math::ceil((double)duration * (double)BAKE_FPS) + 1;
}

<*
 Fills the planned buffer: every rest pose, then every frame of every segment.

 Public for the tests. What matters about a bake is the numbers in it, and they
 are on the device a moment after this returns — checking them through a picture
 would mean a render test for every arithmetic mistake, and a readback would mean
 a staging buffer built for nothing else. So this is callable with an array of
 the caller's own, and `the_rest_pose_is_the_identity` and
 `a_bent_joint_puts_the_tip_where_the_maths_says` run it over the same inputs the
 upload ran it over.

 Deterministic: same asset, same output.

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
	// which is the bind pose, so every matrix here should come out the identity.
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
			// The clip's own numbers: glTF times are absolute and need not start
			// at zero, so a frame is measured from `start` rather than from zero.
			float time = clip.start + (float)frame / segment.fps;
			pose_at(asset, clip, time, scratch, locals, world);

			usz at = (usz)segment.frame_offset + (usz)frame * (usz)segment.joint_count;
			write_joints(asset, skin, world, poses[at..]);
		}
	}
}

<*
 Puts the asset's nodes into the pose a clip holds at `time`, and composes their
 world matrices.

 The same two halves `AnimationPlayer` runs per frame on the live scene graph,
 done here on the asset's own copy of the hierarchy — which is why nothing about
 baking needs a `Scene`, and why a hundred instances share one bake.

 `clip` may be null, meaning the file's own transforms: the bind pose.
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
			// A baked pose is a table of joint matrices and a morph weight is not
			// one, so this is the one channel the bake has nothing to do with — and
			// skipping it *before* the sample matters, because a WEIGHTS channel is
			// as wide as the mesh has targets and `value` is four floats.
			if (channel.path == AnimatedPath.WEIGHTS) continue;
			channel.sample(time, value[..]);

			switch (channel.path)
			{
				case AnimatedPath.TRANSLATION:
					scratch[channel.node].position = { value[0], value[1], value[2] };
				case AnimatedPath.ROTATION:
					scratch[channel.node].rotation = { value[0], value[1], value[2], value[3] };
				case AnimatedPath.SCALE:
					scratch[channel.node].scale = { value[0], value[1], value[2] };
				default:
					break;
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

 `world * inverse_bind`, in that order: the inverse bind takes a vertex out of
 the mesh's bind pose and into the joint's own space, and the world matrix then
 puts it wherever that joint has moved to. Reversing them produces a mesh turned
 inside out around its own root rather than a posed one.
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

 An exact bound would be a pass over every vertex of every frame, buying back a
 handful of draw calls in exchange for the bake becoming the slow part of loading
 a character.
*>
fn void measure_skinned_bounds(Asset* asset, Matrix4f[] poses) @local
{
	collision::Aabb3 bind = asset.bounds;
	bool first = true;

	foreach (pose : poses)
	{
		collision::Aabb3 moved = bind.transform_matrix(pose);
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

<*
 A CPU copy of the baked table, built the first time something asks where a bone
 is and never otherwise.

 **The table is device-local and the device is not readable**, so a socket — "put
 the sword in that hand" — has nowhere to read `pose * bind` from. Three ways out,
 and this is the third:

 - Keeping the array `ensure_poses` already built would double the pose memory of
   every rigged file in the project, whether or not anything ever asks a question
   about a bone.
 - Sampling the clip again along the bone's ancestor chain would answer a slightly
   different question: the curves at the player's exact time, where what is drawn
   is the nearest baked frame. A sword half a bake frame ahead of the hand holding
   it is the kind of wrong that is only visible in motion.
 - Re-running the bake answers exactly the question the GPU is answering, because
   it is the same deterministic function over the same inputs. `Asset.bake_poses`
   is public and says so.

 So a file nothing is socketed to spends nothing, and one that is spends a second
 copy of its pose table — per asset, not per instance, and once.
*>
fn void Assets.ensure_pose_mirror(&self, AssetId id)
{
	Asset* asset = self.slot(id);
	if (asset == null || asset.pose_mirror.len > 0) return;
	if (asset.pose_matrices == 0 || asset.nodes.len() == 0) return;

	asset.pose_mirror = mem::new_array(Matrix4f, (usz)asset.pose_matrices);
	asset.bake_poses(asset.pose_mirror);
}

<*
 Where one joint of one skin sits, for one frame of the baked table.

 `pose * bind`, which is the inverse of what `write_joints` did: the table holds
 `world * inverse_bind`, so multiplying the bind matrix back in leaves the bone's
 own world matrix in the asset's space — the space a socket node's parent is
 already in. **This is what `AssetSkin.bind` is kept for, and the only thing that
 reads it.**

 The identity when the mirror is not built or the offset is off the end, which
 puts a socket at the character's origin: visible and local, rather than a read
 past an array.
*>
fn Matrix4f Asset.bone_matrix(&self, uint skin, uint joint, uint offset)
{
	if (skin >= self.skins.len()) return matrix::IDENTITY4{float};
	AssetSkin* rig = &self.skins[skin];
	if (joint >= rig.bind.len()) return matrix::IDENTITY4{float};

	usz at = (usz)offset + (usz)joint;
	if (at >= self.pose_mirror.len) return matrix::IDENTITY4{float};
	return self.pose_mirror[at].mul(rig.bind[joint]);
}

// ============================================================================
// Sockets
// ============================================================================

<*
 One node kept on one bone of a baked character.

 **Sockets are for the baked path and refuse the live one**, which is not a
 shortfall: a `skeleton: true` character has its bones as scene nodes already, so
 attaching a sword to its hand is `hand.add(sword)` through the ordinary graph and
 a second mechanism beside it would be two answers to one question. A baked
 character has no bone nodes at all — that absence is what makes a hundred of them
 a hundred nodes — so its bone transforms have to be recovered from the pose table
 and written somewhere, and this is the somewhere.
*>
struct Socket
{
	// The node being kept on the bone. Its parent is the character's group, so
	// what is written into it is the bone's transform in the asset's own space and
	// the ordinary world-matrix walk does the rest.
	NodeId node;

	// The skinned mesh whose `pose` says which frame to read — the drawing node
	// and not the group, because the pose offset is per drawn copy.
	NodeId character;
	uint skin;
	uint joint;

	// What the character's pose was the last time this was written. **A character
	// standing still writes nothing and marks nothing moved**, which is what keeps
	// one socket from forcing the world-matrix walk on every frame of a still
	// scene. The three fields together are the whole of what the bone transform
	// depends on, so comparing them is exact rather than a heuristic.
	uint pose;
	uint pose_from;
	float blend;
	bool written;
}

<*
 Puts `node` on the bone called `bone`, somewhere under the character at `root`.

 The node keeps its own identity — it is an ordinary scene node and can hold a
 subtree — and what it loses is its transform, which is overwritten every frame
 the pose changes. Attaching a second node to the same bone is fine and attaching
 one node twice replaces the first attachment.

 Refused on a live character, and the refusal is the useful answer: with
 `skeleton: true` the bone is already a node in the scene, so `getObjectByName`
 finds it and `add` puts something on it, which is one mechanism rather than two.

 @param root : `The group an instantiation returned. The bone is looked for in every skinned mesh under it, so a file with two skinned meshes finds whichever one names it.`
 @return `False when the subtree has no skinned mesh with a joint of that name, or when the character is posed live. A question rather than an error: the bone names are the file's own.`
*>
fn bool Scene.attach_socket(&self, NodeId node, NodeId root, String bone)
{
	if (self.assets == null || self.node(node) == null) return false;

	AnimationPlayer* player = self.player(root);
	if (player != null && player.live_skin) return false;

	NodeId character = NO_NODE;
	uint skin = 0;
	uint joint = 0;
	if (!self.find_bone(root, bone, &character, &skin, &joint)) return false;

	Node* posed = self.node(character);
	if (posed == null) return false;
	self.assets.ensure_pose_mirror(posed.asset);

	self.detach_socket(node);
	self.sockets.push({ .node = node, .character = character, .skin = skin, .joint = joint });
	self.update_sockets();
	return true;
}

<*
 Takes a node off whatever bone it was on, leaving it where the bone last put it.

 @return `Whether it was on one.`
*>
fn bool Scene.detach_socket(&self, NodeId node)
{
	foreach (i, &socket : self.sockets)
	{
		if (socket.node != node) continue;
		self.sockets.remove_at(i);
		return true;
	}
	return false;
}

<*
 The skinned mesh under `id` that has a joint called `bone`, and which joint.

 Recursive over an instantiated character, which is `flatten_node`'s depth
 argument again. The name is the *asset node's*, because that is what a rig calls
 its bones and what a file's author typed.
*>
fn bool Scene.find_bone(&self, NodeId id, String bone, NodeId* character, uint* skin, uint* joint)
{
	Node* node = self.node(id);
	if (node == null) return false;

	if (node.skin >= 0)
	{
		Asset* owner = self.assets.slot(node.asset);
		if (owner != null && node.skin < owner.skins.len())
		{
			AssetSkin* rig = &owner.skins[node.skin];
			foreach (j, source : rig.joints)
			{
				if (source >= owner.nodes.len()) continue;
				if (owner.nodes[source].name != bone) continue;

				*character = id;
				*skin = (uint)node.skin;
				*joint = (uint)j;
				return true;
			}
		}
	}

	foreach (child : node.children)
	{
		if (self.find_bone(child, bone, character, skin, joint)) return true;
	}
	return false;
}

<*
 Every socket put back on its bone, for the pose its character is in now.

 Runs once a frame from `step_animations`, and again from `play` so that a
 character posed without the clock being stepped drags what is attached to it
 along. Costs nothing in a scene with no sockets and nothing in a frame where
 nothing moved — see `Socket.pose`.

 A socket whose node or character has been killed is dropped here rather than by
 the kill: a node's death is one of several, and sweeping the short list at the
 one place that walks it anyway is cheaper than a hook on the frequent path.
*>
fn void Scene.update_sockets(&self)
{
	if (self.sockets.len() == 0 || self.assets == null) return;

	// Backwards, so removing an entry does not skip the one after it.
	for (sz i = self.sockets.len(); i > 0; i--)
	{
		Socket* socket = &self.sockets[i - 1];
		Node* node = self.node(socket.node);
		Node* character = self.node(socket.character);
		if (node == null || character == null)
		{
			self.sockets.remove_at(i - 1);
			continue;
		}

		if (socket.written
			&& socket.pose == character.pose
			&& socket.pose_from == character.pose_from
			&& socket.blend == character.blend)
		{
			continue;
		}

		Asset* owner = self.assets.slot(character.asset);
		if (owner == null) continue;

		Matrix4f world = owner.bone_matrix(socket.skin, socket.joint, character.pose);
		if (character.blend > 0)
		{
			// The same mix the shader makes, and the same lie with it: what a
			// socket has to be is where the crossfading hand *is*, not where either
			// clip on its own would have put it.
			Matrix4f from = owner.bone_matrix(socket.skin, socket.joint, character.pose_from);
			world = mix_matrix(world, from, character.blend);
		}

		decompose(world, &node.position, &node.rotation, &node.scale);
		self.mark_moved(socket.node);

		socket.pose = character.pose;
		socket.pose_from = character.pose_from;
		socket.blend = character.blend;
		socket.written = true;
	}
}

<*
 Two matrices mixed componentwise, `weight` of the second.

 The socket's half of `shaders/mesh.slang`'s crossfade, and wrong in exactly the
 way that one is wrong — deliberately, because a socket that took the honest path
 would drift away from the hand the shader drew.
*>
fn Matrix4f mix_matrix(Matrix4f to, Matrix4f from, float weight) @local
{
	Matrix4f mixed;
	for (usz i = 0; i < 16; i++) mixed.m[i] = to.m[i] + (from.m[i] - to.m[i]) * weight;
	return mixed;
}
