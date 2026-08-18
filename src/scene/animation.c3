<*
 glTF node animation: the clips a file carries, and the sampling that turns one
 into a transform.

 `game.md` G3/S4 and S5. Two halves, and the split between them is the whole
 design:

 - **A clip is on the asset.** Keyframes are immutable data read once per file,
   and a hundred copies of a walking character share one copy of the walk.
 - **A player is on the instance.** Two copies of the same tree must be able to
   wave at different phases, so the time, the speed and the loop flag live beside
   the nodes, not beside the keys. This is the first per-instance state in the
   scene model that is not a transform, which is worth saying out loud: until now
   a node was an asset reference plus a matrix and nothing else.

 ## Sampling is not deferred to a library

 `gltf.c3l` has `Animation.duration`, `loop_time` and `clamp_time` and they are
 used. It also has a whole-node sampler; that one is not, because it walks every
 channel of an animation looking for the frame and returns a matrix, and what a
 `three::Node` wants is a TRS triple written into three fields. Reading the
 keyframes into three.c3's own arrays once, at first play, is both faster per
 frame and the thing that makes `CUBICSPLINE` implementable rather than
 approximated.

 ## What a clip does *not* do

 No blending, no crossfade, no additive layers. `game.md` G3/S7 says why: Three.js's
 `AnimationMixer` earns its complexity on crossfading, and crossfading is worth
 having after G4, when blending between clips is what makes a character look
 right. A partial mixer answering to the same name would be worse than a
 deliberately smaller thing with a different one.
*>
module three;

import std::collections::list;
import std::math;
import std::math::vector;
import std::math::quaternion;
import gltf;

// ============================================================================
// The data
// ============================================================================

<*
 Which of a node's three transform channels a curve drives.

 glTF also has `WEIGHTS` (morph targets) and `POINTER` (the extension that can
 animate anything). Neither is here: there is no morph target support to drive,
 and a channel three.c3 cannot apply is dropped at read time rather than carried
 as a case every switch has to answer.
*>
enum AnimatedPath
{
	TRANSLATION,
	ROTATION,
	SCALE,
}

<*
 One curve: a list of times, a list of values, and which node's which channel it
 drives.

 `times` and `values` are three.c3's own copies rather than views into the glTF
 buffer. The buffer is mmapped and could be read in place, but an accessor may be
 strided — `@cast_buffer` is what knows that — and paying the stride arithmetic
 once at first play rather than twice per node per frame is the whole reason to
 copy.
*>
struct AnimationChannel
{
	uint node; // glTF node index, which is what a channel targets

	AnimatedPath path;
	gltf::Interpolation interp;

	// Owned. `times` is one float per key; `values` is `stride` floats per key,
	// or three times that for CUBICSPLINE, which stores an in-tangent and an
	// out-tangent either side of each value.
	float[] times;
	float[] values;

	// 3 for a translation or a scale, 4 for a rotation.
	uint stride;
}

<*
 A named clip, and the curves that make it up.

 Names, durations and channel targets are read at `Assets.load` — they are in the
 JSON chunk, so this costs nothing and `mesh.animations` can answer without any
 buffer being touched. **The keyframes are not**, for G3/S3's reason: a file
 describes itself cheaply and pays when it is used. `Assets.ensure_clip` is where
 the curves arrive, and it happens on the first `play` of that clip.
*>
struct AnimationClip
{
	String name; // owned

	// glTF times are absolute and need not start at zero; `start` is the file's
	// own `min_time` and `duration` is `max_time - min_time`. Keeping both means
	// looping is arithmetic on the file's numbers rather than on a shifted copy
	// of them.
	float start;
	float duration;

	// Index into the file's own `animations`, for reading the curves later.
	uint source;

	List{AnimationChannel} channels;
	bool loaded;
}

<*
 Give back one clip's curves and its name.
*>
fn void AnimationClip.free(&self)
{
	foreach (&channel : self.channels)
	{
		if (channel.times.len > 0) mem::free(channel.times);
		if (channel.values.len > 0) mem::free(channel.values);
	}
	self.channels.free();
	self.channels = {};
	if (self.name.len > 0) self.name.free(mem);
	self.name = "";
	self.loaded = false;
}

// ============================================================================
// Sampling
// ============================================================================

<*
 Where in a channel's key list a time falls: the key at or before it, and how far
 between that key and the next.

 A linear scan from the start would be O(keys) per channel per frame and a walk
 cycle has a few dozen keys, so it would not actually matter — but a binary
 search is four lines and removes the question, and G4's skinned characters have
 a channel per joint rather than per node.
*>
fn usz find_keyframe(float[] times, float time, float* fraction) @local
{
	*fraction = 0;
	if (times.len <= 1) return 0;
	if (time <= times[0]) return 0;
	if (time >= times[times.len - 1]) return times.len - 1;

	usz low = 0;
	usz high = times.len - 1;
	while (high - low > 1)
	{
		usz mid = (low + high) / 2;
		if (times[mid] <= time) { low = mid; } else { high = mid; }
	}

	float span = times[high] - times[low];
	// Two keys at the same instant are legal and mean a step; dividing by the
	// gap would be a NaN that then propagates into a world matrix.
	*fraction = span > 0 ? (time - times[low]) / span : 0;
	return low;
}

<*
 Sample a channel at `time` into up to four floats.

 The three glTF interpolations, all of them:

 - **STEP** holds the earlier key. Used for anything that should pop rather than
   slide — a light switching, a prop appearing.
 - **LINEAR** interpolates. For a rotation that means **slerp**, not a
   component-wise mix: the spec says so, and a component-wise mix of two
   quaternions 90° apart is a rotation that speeds up in the middle and is not a
   unit quaternion on the way.
 - **CUBICSPLINE** stores three values per key — in-tangent, value, out-tangent —
   and interpolates with a Hermite spline. The tangents are scaled by the key
   spacing, which is the part that is wrong in every implementation that treats
   them as if the interval were one second.

 @param out : `At least four floats; only the channel's own stride is written.`
*>
fn void AnimationChannel.sample(&self, float time, float[] out)
{
	if (self.times.len == 0) return;

	uint stride = self.stride;
	bool spline = self.interp == gltf::Interpolation.CUBICSPLINE;
	// CUBICSPLINE stores [in-tangent, value, out-tangent] per key, so the value
	// of key `k` is at `k * 3 * stride + stride`.
	uint block = spline ? stride * 3 : stride;
	uint value_offset = spline ? stride : 0;

	float fraction;
	usz key = find_keyframe(self.times, time, &fraction);
	usz next = key + 1 < self.times.len ? key + 1 : key;

	usz a = key * (usz)block + (usz)value_offset;
	usz b = next * (usz)block + (usz)value_offset;

	if (key == next || self.interp == gltf::Interpolation.STEP || fraction <= 0)
	{
		for (uint i = 0; i < stride; i++) out[i] = self.values[a + i];
		return;
	}

	if (spline)
	{
		float span = self.times[next] - self.times[key];
		float t = fraction;
		float t2 = t * t;
		float t3 = t2 * t;

		float h00 = 2 * t3 - 3 * t2 + 1;
		float h10 = t3 - 2 * t2 + t;
		float h01 = -2 * t3 + 3 * t2;
		float h11 = t3 - t2;

		// The out-tangent of the earlier key and the in-tangent of the later one,
		// both scaled by the interval — glTF stores tangents per unit of the
		// *parameter*, and the parameter here is seconds.
		usz out_tangent = key * (usz)block + (usz)stride * 2;
		usz in_tangent = next * (usz)block;

		for (uint i = 0; i < stride; i++)
		{
			out[i] = h00 * self.values[a + i]
				+ h10 * span * self.values[out_tangent + i]
				+ h01 * self.values[b + i]
				+ h11 * span * self.values[in_tangent + i];
		}
		if (self.path == AnimatedPath.ROTATION) normalize_into(out);
		return;
	}

	if (self.path == AnimatedPath.ROTATION)
	{
		Quaternionf from = { self.values[a], self.values[a + 1], self.values[a + 2], self.values[a + 3] };
		Quaternionf to = { self.values[b], self.values[b + 1], self.values[b + 2], self.values[b + 3] };
		Quaternionf mixed = from.slerp(to, fraction);
		out[0] = mixed.i;
		out[1] = mixed.j;
		out[2] = mixed.k;
		out[3] = mixed.l;
		return;
	}

	for (uint i = 0; i < stride; i++)
	{
		out[i] = self.values[a + i] + (self.values[b + i] - self.values[a + i]) * fraction;
	}
}

<*
 Make four floats a unit quaternion, or the identity if they are not a rotation
 at all.

 A Hermite spline through unit quaternions does not stay on the unit sphere, so
 the normalize is required rather than defensive. The zero-length guard is: a
 spline whose tangents cancel exactly produces one, and dividing by it would put
 NaNs into a node and from there into every descendant.
*>
fn void normalize_into(float[] value) @local
{
	float length_sq = value[0] * value[0] + value[1] * value[1] + value[2] * value[2] + value[3] * value[3];
	if (length_sq < 1e-12f)
	{
		value[0] = 0;
		value[1] = 0;
		value[2] = 0;
		value[3] = 1;
		return;
	}
	float inv = 1.0f / math::sqrt(length_sq);
	value[0] *= inv;
	value[1] *= inv;
	value[2] *= inv;
	value[3] *= inv;
}

// ============================================================================
// The player, which is per instance
// ============================================================================

<*
 One instantiated subtree's animation state.

 **Per instance, which is the point.** Two copies of the same character have one
 copy of the walk cycle and two of these, so they can be at different phases —
 the thing that is impossible if the time lives on the asset, and the reason this
 is a separate structure at all.

 `targets` is what makes a clip addressable: a channel names a *glTF node index*,
 and `Scene.instantiate` is the only thing that knows which `NodeId` that became.
 The map is built there and kept here, indexed by glTF node index, holding
 `NO_NODE` for a node the instantiation did not produce.

 A player exists for every instantiated subtree of an asset that has clips, even
 before anything plays — building it lazily would mean `play()` needed the
 instantiation walk again, and the walk is the expensive half.
*>
struct AnimationPlayer
{
	// The group `instantiate` returned. Identity and lifetime both: the player
	// goes when this node does.
	NodeId root;
	AssetId asset;

	// By glTF node index. Owned.
	List{NodeId} targets;

	// -1 when nothing is playing, which is the state a player spends most of its
	// life in and is not the same as "no player".
	int clip;
	float time;
	float speed;
	bool loop;
	bool playing;
}

fn void AnimationPlayer.free(&self)
{
	self.targets.free();
	self.targets = {};
}

<*
 Advance a player by `dt` seconds and write the result into its nodes.

 Time is in the clip's own units, which glTF says are seconds and need not start
 at zero. A finished non-looping clip stops *on its last frame* rather than
 snapping back — `clamp_time` — because a character that finishes a "sit down"
 and returns to standing is the animation bug everyone writes once.

 Nodes are marked dirty rather than having their world matrices recomputed here.
 `update_world_matrices` runs once per frame over the whole scene and already
 carries a dirty flag down a subtree; doing it per channel would recompute a
 hand's matrix once per joint above it.
*>
fn void AnimationPlayer.advance(&self, Scene* scene, Assets* assets, float dt)
{
	if (!self.playing || self.clip < 0) return;

	Asset* owner = assets.slot(self.asset);
	if (owner == null || self.clip >= owner.clips.len())
	{
		self.playing = false;
		return;
	}

	AnimationClip* clip = &owner.clips[self.clip];
	self.time += dt * self.speed;

	if (self.loop)
	{
		self.time = (float)clip_loop_time(clip, self.time);
	}
	else if (self.time >= clip.start + clip.duration)
	{
		self.time = clip.start + clip.duration;
		self.playing = false;
	}
	else if (self.time < clip.start)
	{
		// A negative speed running off the front, which is a legitimate way to
		// play something backwards.
		self.time = clip.start;
		self.playing = false;
	}

	self.apply(scene, clip);
}

<*
 Write the clip's value at the player's current time into every node it targets.

 Split from `advance` so that `play()` can pose an instance at frame zero without
 stepping it — a prop that is placed paused should look like its first frame, not
 like whatever its rest pose happened to be.
*>
fn void AnimationPlayer.apply(&self, Scene* scene, AnimationClip* clip)
{
	float[4] value;

	foreach (&channel : clip.channels)
	{
		if (channel.node >= self.targets.len()) continue;
		NodeId id = self.targets[channel.node];
		if (!id.is_set()) continue;

		Node* node = scene.node(id);
		if (node == null) continue;

		channel.sample(self.time, value[..]);

		switch (channel.path)
		{
			case AnimatedPath.TRANSLATION:
				node.position = { value[0], value[1], value[2] };
			case AnimatedPath.ROTATION:
				node.rotation = { value[0], value[1], value[2], value[3] };
			case AnimatedPath.SCALE:
				node.scale = { value[0], value[1], value[2] };
		}
		node.dirty = true;
	}
}

<*
 `time` wrapped into the clip's range, on the clip's own numbers.

 `gltf::Animation.loop_time` does this and is not reachable from here — a
 `three::AnimationClip` is not a `gltf::Animation`, and it deliberately outlives
 the point at which one is available. Same arithmetic, kept honest by
 `a_loop_wraps_to_the_same_pose`.
*>
fn double clip_loop_time(AnimationClip* clip, double time) @local
{
	if (clip.duration <= 0) return clip.start;
	double t = time - clip.start;
	t = t - math::floor(t / clip.duration) * clip.duration;
	return t + clip.start;
}
