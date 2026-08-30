<*
 glTF node animation: the clips a file carries, and the sampling that turns one
 into a transform.

 Two halves, and the split between them is the design:

 - A clip is on the asset. Keyframes are immutable data read once per file, so a
   hundred copies of a walking character share one copy of the walk.
 - A player is on the instance. Two copies of the same tree must be able to wave
   at different phases, so the time, the speed and the loop flag live beside the
   nodes rather than beside the keys. This is the first per-instance state in the
   scene model that is not a transform.

 `gltf.c3l`'s `Animation.duration`, `loop_time` and `clamp_time` are used; its
 whole-node sampler is not, because it walks every channel looking for the frame
 and returns a matrix, where a `three::Node` wants a TRS triple written into
 three fields. Reading the keyframes into three.c3's own arrays once, at first
 play, is faster per frame and is what makes `CUBICSPLINE` implementable rather
 than approximated.

 There is a crossfade and there are no additive layers. The fade is two clips and
 one weight — `play(name, { fade })` and nothing else to hold — where Three.js's
 `AnimationMixer` is a graph of actions with their own weights, timescales and
 loop counts. Two clips is what a locomotion state machine actually asks for, and
 the third one is the point at which a mixer would have to be a mixer.
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
 What a curve drives: one of a node's three transform channels, or the morph
 weights of the mesh it draws.

 **`WEIGHTS` is the odd one and every switch over this has to know why.** The
 other three write one fixed-width value into a `Node`; this one writes as many
 floats as the mesh has morph targets, which is a number the channel carries
 rather than a constant — so a caller sampling into four floats would overflow on
 a face with twenty expressions. The bake skips it outright: a baked pose table
 holds joint matrices, and a weight is not one.

 glTF's `POINTER` — the extension that can animate anything — is still not here. A
 channel three.c3 cannot apply is dropped at read time rather than carried as a
 case every switch has to answer.
*>
enum AnimatedPath
{
	TRANSLATION,
	ROTATION,
	SCALE,
	WEIGHTS,
}

<*
 One curve: a list of times, a list of values, and which node's which channel it
 drives.

 `times` and `values` are three.c3's own copies rather than views into the glTF
 buffer. The buffer is mmapped and could be read in place, but an accessor may be
 strided, and paying the stride arithmetic once at first play rather than twice
 per node per frame is the whole reason to copy.
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
 buffer being touched. The keyframes are not: `Assets.ensure_clip` reads the
 curves on the first `play` of that clip.
*>
struct AnimationClip
{
	String name; // owned

	// glTF times are absolute and need not start at zero; `start` is the file's
	// own `min_time` and `duration` is `max_time - min_time`. Keeping both means
	// looping is arithmetic on the file's numbers rather than on a shifted copy.
	float start;
	float duration;

	// Index into the file's own `animations`, for reading the curves later.
	uint source;

	List{AnimationChannel} channels;
	bool loaded;
}

<*
 Gives back one clip's curves and its name.
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

 A binary search. A linear scan would be O(keys) per channel per frame, which for
 a walk cycle's few dozen keys would not actually matter — but this is four lines
 and removes the question, and a skinned character has a channel per joint.
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
	// Two keys at the same instant are legal and mean a step; dividing by the gap
	// would be a NaN that then propagates into a world matrix.
	*fraction = span > 0 ? (time - times[low]) / span : 0;
	return low;
}

<*
 Samples a channel at `time` into up to four floats.

 All three glTF interpolations:

 - STEP holds the earlier key. For anything that should pop rather than slide —
   a light switching, a prop appearing.
 - LINEAR interpolates. For a rotation that means *slerp*, not a component-wise
   mix: the spec says so, and a component-wise mix of two quaternions 90° apart
   speeds up in the middle and is not a unit quaternion on the way.
 - CUBICSPLINE stores three values per key — in-tangent, value, out-tangent —
   and interpolates with a Hermite spline. The tangents are scaled by the key
   spacing, which is the part that is wrong in every implementation that treats
   the interval as one second.

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
 Makes four floats a unit quaternion, or the identity if they are not a rotation
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
 One skinned mesh this player poses, and which of the asset's skins poses it.

 Kept beside `targets` rather than looked up per frame: the alternative is
 walking the subtree once a frame per character to ask which of its nodes are
 characters, and the answer cannot change — a node's skin is set when it is
 created and cleared when its slot is recycled.
*>
struct SkinnedTarget
{
	NodeId node;
	uint skin;
}


<*
 One instantiated subtree's animation state.

 Per instance, which is the point: two copies of the same character have one copy
 of the walk cycle and two of these, so they can be at different phases.

 `targets` is what makes a clip addressable. A channel names a *glTF node index*,
 and `Scene.instantiate` is the only thing that knows which `NodeId` that became;
 the map is built there and kept here, indexed by glTF node index, holding
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

	// The skinned meshes under `root`, usually one and never many. Owned.
	//
	// What makes a crowd cost nothing: advancing a baked character is stepping
	// the clock, dividing by the frame rate, and writing one `uint` per entry
	// here. No palette to compute, nothing to upload, no per-joint work — the
	// sixty matrices this would otherwise produce were baked when the file first
	// drew and are shared by every copy in the scene.
	List{SkinnedTarget} skinned;

	// -1 when nothing is playing, which is the state a player spends most of its
	// life in and is not the same as "no player".
	int clip;
	float time;
	float speed;
	bool loop;
	bool playing;

	<*
	 The clip a crossfade is coming out of, and its own clock. -1 when nothing is
	 fading, which is every frame but the fraction of a second after a `play` that
	 asked for one.

	 **Its own clock, not a frozen frame.** A walk faded into a wave goes on
	 walking underneath for the length of the fade; holding the walk still would
	 make the legs stop a beat before the arms move, which reads as a hitch rather
	 than as a transition.

	 One clip deep. A second `play` during a fade drops whatever was fading out and
	 fades from the clip that was fading *in* — three-way blending is where a mixer
	 starts, and the header says why this is not one.
	*>
	int from_clip;
	float from_time;
	float from_speed;
	bool from_loop;

	// Seconds into the fade, and how long it lasts. `fade / fade_duration` is how
	// much of `clip` has arrived, and reaching 1 is what clears `from_clip`.
	float fade;
	float fade_duration;

	<*
	 Whether this character's joint matrices are computed every frame from its
	 bone nodes, rather than keyed out of the baked table.

	 Set by `instantiate({ skeleton: true })`, and the whole of what that flag
	 buys: the bones exist as scene nodes, so a script can write one and the skin
	 follows — a look-at, an aim offset, a foot planted on a slope — and the time
	 is exact rather than snapped to the bake rate.

	 It is a cost dial. A live character pays a hierarchy walk over its own bones
	 and a palette write every frame; a baked one pays one `uint`. That is the
	 difference between a hero and a crowd, and why the default is the crowd.
	*>
	bool live_skin;

	<*
	 Room for one WEIGHTS sample, which is as wide as the mesh has morph targets.

	 Kept on the player and grown once rather than taken from a scratch arena per
	 frame: the width is a property of the character and does not change, so the
	 first frame that morphs pays for the last. Empty on every player that never
	 touches a weight channel, which is almost all of them.
	*>
	List{float} weight_scratch;
}

fn void AnimationPlayer.free(&self)
{
	self.targets.free();
	self.targets = {};
	self.skinned.free();
	self.skinned = {};
	self.weight_scratch.free();
	self.weight_scratch = {};
}

<*
 Advances a player by `dt` seconds and writes the result into its nodes.

 Time is in the clip's own units, which glTF says are seconds and need not start
 at zero. A finished non-looping clip stops *on its last frame* rather than
 snapping back (`clamp_time`), because a character that finishes a "sit down" and
 returns to standing is the animation bug everyone writes once.

 Nodes are marked dirty rather than having their world matrices recomputed here.
 `update_world_matrices` runs once per frame over the whole scene and already
 carries a dirty flag down a subtree; doing it per channel would recompute a
 hand's matrix once per joint above it.
*>
fn void AnimationPlayer.advance(&self, Scene* scene, Assets* assets, float dt)
{
	if (self.clip < 0) return;
	// A fade outlives the clip it is fading *into* stopping: a one-shot shorter
	// than the fade would otherwise freeze half-blended, since a stopped player
	// steps nothing.
	if (!self.playing && self.from_clip < 0) return;

	Asset* owner = assets.slot(self.asset);
	if (owner == null || self.clip >= owner.clips.len())
	{
		self.playing = false;
		self.from_clip = -1;
		return;
	}

	AnimationClip* clip = &owner.clips[self.clip];
	if (self.playing) self.time = step_time(clip, self.time, self.speed, self.loop, dt, &self.playing);

	AnimationClip* from = null;
	if (self.from_clip >= 0 && self.from_clip < owner.clips.len())
	{
		from = &owner.clips[self.from_clip];
		// Whether the outgoing clip has run out is not interesting — it is on its
		// way out either way — so the flag it would set is a local nothing reads.
		bool running = true;
		self.from_time = step_time(from, self.from_time, self.from_speed, self.from_loop, dt, &running);

		self.fade += dt;
		if (self.fade >= self.fade_duration)
		{
			self.from_clip = -1;
			from = null;
		}
	}
	else
	{
		self.from_clip = -1;
	}

	if (from != null)
	{
		self.apply_blend(scene, owner, from, clip);
	}
	else
	{
		self.write_clip(scene, clip, self.time, 1.0f);
	}
	self.key_pose(scene, owner, clip);
}

<*
 One clock stepped by `dt`, wrapped or clamped on the clip's own numbers.

 Shared by the playing clip and the one a crossfade is leaving behind, which is
 the whole reason it is a function: the outgoing clip has to run under exactly the
 rules it was playing under a moment ago, and two copies of this arithmetic would
 be two chances to disagree about the endpoint.

 @param playing : `Cleared when a non-looping clip runs off either end, and left alone otherwise.`
*>
fn float step_time(AnimationClip* clip, float time, float speed, bool loop, float dt, bool* playing) @local
{
	time += dt * speed;

	if (loop) return (float)clip_loop_time(clip, time);

	if (time >= clip.start + clip.duration)
	{
		*playing = false;
		return clip.start + clip.duration;
	}
	if (time < clip.start)
	{
		// A negative speed running off the front, which is a legitimate way to
		// play something backwards.
		*playing = false;
		return clip.start;
	}
	return time;
}

<*
 How much of the incoming clip has arrived: 0 at the moment the fade starts, 1
 when it is over, and 1 whenever nothing is fading.

 Read by both halves — the live path mixes the nodes by it and the baked path
 hands it to the shader — so a character does not fade at two different rates
 depending on which one is posing it.
*>
fn float AnimationPlayer.blend_weight(&self)
{
	if (self.from_clip < 0 || self.fade_duration <= 0) return 1.0f;
	float weight = self.fade / self.fade_duration;
	if (weight <= 0) return 0;
	if (weight >= 1) return 1.0f;
	return weight;
}

<*
 Both clips written into the nodes, mixed by the fade's weight.

 **This is the honest half of the crossfade.** It blends the transforms rather
 than the matrices they compose into — a lerp on translation and scale, a slerp on
 rotation — so a joint mid-fade is a rotation of the right length and the limb
 keeps its bones. `shaders/mesh.slang` explains what the baked path does instead
 and why it is allowed to be worse.

 Three passes over the channels rather than one, and only while a fade is running.
*>
fn void AnimationPlayer.apply_blend(
	&self,
	Scene* scene,
	Asset* owner,
	AnimationClip* from,
	AnimationClip* to
)
{
	// Every node either clip drives, back to the file's own transform first. A
	// joint that only one of the two names would otherwise blend out of wherever
	// last frame left it — a drift with no cause a script can see, and one that
	// depends on which clip was playing before.
	self.reset_targets(scene, owner, from);
	self.reset_targets(scene, owner, to);

	self.write_clip(scene, from, self.from_time, 1.0f);
	self.write_clip(scene, to, self.time, self.blend_weight());
}

<*
 Every node a clip targets, back to the transform the file gave it.

 The asset's own nodes are the bind pose, and `Asset.nodes` is indexed by glTF
 node index — the same index a channel targets and the same one `targets` is
 keyed by, which is what makes this three lookups and no search.
*>
fn void AnimationPlayer.reset_targets(&self, Scene* scene, Asset* owner, AnimationClip* clip)
{
	foreach (&channel : clip.channels)
	{
		if (channel.node >= self.targets.len() || channel.node >= owner.nodes.len()) continue;
		NodeId id = self.targets[channel.node];
		if (!id.is_set()) continue;

		Node* node = scene.node(id);
		if (node == null) continue;

		if (channel.path == AnimatedPath.WEIGHTS)
		{
			// A morph weight's rest value is zero — the neutral mesh — and clearing
			// takes the copy off the morph path entirely rather than leaving it
			// paying for a loop over zeroes.
			scene.clear_morph_weights(id);
			continue;
		}

		AssetNode* source = &owner.nodes[channel.node];
		node.position = source.position;
		node.rotation = source.rotation;
		node.scale = source.scale;
	}
}

<*
 One transform mixed toward another. `weight >= 1` is the plain assignment the
 unblended path wants, and it is an early return rather than a lerp by 1 so that
 the ordinary case costs nothing and lands on exactly the sampled value.
*>
fn Vec3 mix_vec(Vec3 from, Vec3 to, float weight) @local
{
	if (weight >= 1.0f) return to;
	return from + (to - from) * weight;
}

<*
 The same for a rotation, and a slerp rather than a lerp for `sample`'s reason: a
 component-wise mix of two quaternions is not a unit quaternion and speeds up in
 the middle of the arc.
*>
fn Quaternionf mix_quat(Quaternionf from, Quaternionf to, float weight) @local
{
	if (weight >= 1.0f) return to;
	return from.slerp(to, weight);
}

<*
 Points every skinned mesh under this player at the baked frame nearest the
 player's current time.

 The whole of what posing a baked character costs: a divide, a round, a clamp and
 one store per skinned mesh. No matrices are touched and nothing is uploaded.

 Snapped rather than interpolated, which is the design's one visible compromise:
 at thirty frames a second a walk cycle is a walk cycle, and a performance slow
 enough to show the stepping is what the live palette is for.

 A skin the asset never baked — the buffer failed, or the file has clips and no
 skeleton — leaves `pose` where `Scene.set_skin` put it, which is the rest pose.
*>
fn void AnimationPlayer.key_pose(&self, Scene* scene, Asset* owner, AnimationClip* clip)
{
	if (self.skinned.len() == 0 || self.clip < 0) return;
	// A live character's offset is written by `MeshPass.write_live_poses` from
	// the bone nodes `apply` has just posed. Keying a baked frame on top would be
	// two writers for one field, and which one won would depend on call order.
	if (self.live_skin) return;

	// The clip a fade is leaving, if there is one and the bake holds it. A clip the
	// bake does not have cancels the fade for this character rather than blending
	// against a stranger's matrices, which is the same refusal `write_joints` makes
	// one level down.
	AnimationClip* previous = null;
	if (self.from_clip >= 0 && self.from_clip < owner.clips.len())
	{
		previous = &owner.clips[self.from_clip];
	}
	float weight = self.blend_weight();

	foreach (&target : self.skinned)
	{
		BakedPose* segment = owner.segment(target.skin, (uint)self.clip);
		if (segment == null) continue;

		Node* node = scene.node(target.node);
		if (node == null) continue;

		// Rounded, not truncated: truncation biases every pose half a frame early
		// and makes a clip that ends exactly on its last key stop one frame short
		// of it.
		int frame = (int)((self.time - clip.start) * segment.fps + 0.5f);
		node.pose = segment.frame_at(frame);

		node.pose_from = 0;
		node.blend = 0;
		if (previous == null) continue;

		BakedPose* was = owner.segment(target.skin, (uint)self.from_clip);
		if (was == null) continue;

		int from_frame = (int)((self.from_time - previous.start) * was.fps + 0.5f);
		node.pose_from = was.frame_at(from_frame);
		// How much of the *outgoing* frame is still showing, which is the shader's
		// sense of the field and the opposite of `blend_weight`'s. Inverted here
		// rather than there so that zero — a copy that never faded, a recycled slot
		// — means "not fading" everywhere it is read.
		node.blend = 1.0f - weight;
	}
}

<*
 Writes a clip's value at `time` into every node it targets, mixed in by `weight`.

 `weight` of 1 is the plain write, and is what everything but the second half of a
 crossfade asks for. Below 1 the sampled value is mixed into whatever the node
 already holds, which is what makes the fade two calls to this and no third
 buffer: the outgoing clip is written straight and the incoming one is mixed over
 it.

 Split from `advance` so `play()` can pose an instance at frame zero without
 stepping it — a prop placed paused should look like its first frame, not like
 whatever its rest pose happened to be.
*>
fn void AnimationPlayer.write_clip(&self, Scene* scene, AnimationClip* clip, float time, float weight)
{
	float[4] value;

	foreach (&channel : clip.channels)
	{
		if (channel.node >= self.targets.len()) continue;
		NodeId id = self.targets[channel.node];
		if (!id.is_set()) continue;

		Node* node = scene.node(id);
		if (node == null) continue;

		// Wider than four floats and written somewhere else entirely, so it takes
		// the door of its own rather than a fourth case below.
		if (channel.path == AnimatedPath.WEIGHTS)
		{
			self.write_weights(scene, channel, id, time, weight);
			continue;
		}

		channel.sample(time, value[..]);

		switch (channel.path)
		{
			case AnimatedPath.TRANSLATION:
				node.position = mix_vec(node.position, (Vec3) { value[0], value[1], value[2] }, weight);
			case AnimatedPath.ROTATION:
				node.rotation = mix_quat(node.rotation, (Quaternionf) { value[0], value[1], value[2], value[3] }, weight);
			case AnimatedPath.SCALE:
				node.scale = mix_vec(node.scale, (Vec3) { value[0], value[1], value[2] }, weight);
			default:
				break;
		}
		// Not `node.dirty = true`: the flag alone is not enough now that the
		// world-matrix walk may skip itself. See `Scene.mark_moved`.
		scene.mark_moved(id);
	}
}

<*
 The nodes and the skin put where the player's clocks already say, without
 stepping anything.

 What `play` needs, and the only caller: a prop placed and played in the same
 breath should look like its first frame rather than like its rest pose for one
 frame — and when the play asked for a crossfade, like the first frame of the
 fade rather than like a snap onto the new clip.
*>
fn void AnimationPlayer.repose(&self, Scene* scene, Asset* owner)
{
	if (self.clip < 0 || self.clip >= owner.clips.len()) return;
	AnimationClip* clip = &owner.clips[self.clip];

	if (self.from_clip >= 0 && self.from_clip < owner.clips.len())
	{
		self.apply_blend(scene, owner, &owner.clips[self.from_clip], clip);
	}
	else
	{
		self.write_clip(scene, clip, self.time, 1.0f);
	}
	self.key_pose(scene, owner, clip);
}

<*
 One WEIGHTS channel's sample, mixed into the node's morph weights.

 The channel's width is the mesh's morph target count and the node's is too, but
 they are read from different places — the sampler's accessor and the primitive's
 target list — so the shorter of the two is what gets written. A file whose two
 disagree is malformed, and writing the overlap leaves the rest at zero rather
 than reading past either.

 Mixed by `weight` exactly as a transform channel is, so a crossfade between two
 clips that both drive an expression lands between them instead of snapping.

 **A glTF node with several primitives only morphs its first.** Each primitive
 became its own scene node and only one of them carries the glTF index a channel
 names, so this reaches that one. A face is one primitive in every file that
 exists; a face split across two materials is where this would show.
*>
fn void AnimationPlayer.write_weights(
	&self,
	Scene* scene,
	AnimationChannel* channel,
	NodeId id,
	float time,
	float weight
)
{
	uint targets = scene.morph_target_count(id);
	if (targets == 0 || channel.stride == 0) return;

	while (self.weight_scratch.len() < channel.stride) self.weight_scratch.push(0);
	channel.sample(time, self.weight_scratch.array_view());

	uint count = channel.stride < targets ? channel.stride : targets;
	if (weight < 1.0f)
	{
		// Read before the write below, which may free the entry this views into.
		float[] current = scene.morph_weights(id);
		for (uint i = 0; i < count && i < current.len; i++)
		{
			self.weight_scratch[i] = current[i] + (self.weight_scratch[i] - current[i]) * weight;
		}
	}

	scene.set_morph_weights(id, self.weight_scratch.array_view()[0:count]);
}

<*
 `time` wrapped into the clip's range, on the clip's own numbers.

 `gltf::Animation.loop_time` does this and is not reachable from here — a
 `three::AnimationClip` is not a `gltf::Animation`, and it deliberately outlives
 the point at which one is available. Same arithmetic, kept honest by
 `a_loop_wraps_to_the_same_pose`.

 Not `@local`: `Scene.play`'s start phase means a crowd spread with
 `i / count * duration` hands in a time past the end on its last copy, and the
 wrap that makes that mean "the start again" is this one.
*>
fn double clip_loop_time(AnimationClip* clip, double time)
{
	if (clip.duration <= 0) return clip.start;
	double t = time - clip.start;
	t = t - math::floor(t / clip.duration) * clip.duration;
	return t + clip.start;
}
