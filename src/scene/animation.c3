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

 A player is a stack of up to four weighted clips (`AnimationLayer`), with no
 additive layers and no action objects: `play(name, { fade })` raises one clip and
 lowers the rest, `Scene.blend` holds several at the weights it is given, and the
 weights belong to the character rather than to handles a script has to keep.
 Three.js's `AnimationMixer` is a graph of actions with their own weights,
 timescales and loop counts; what a locomotion state machine asks for is a walk
 and a run held by speed, a jump crossfaded over them and an idle to come back to,
 and four clips on one stack is that.
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
	self.channels = { };
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

	usz low  = 0;
	usz high = times.len - 1;
	while (high - low > 1)
	{
		usz mid = (low + high) / 2;
		if (times[mid] <= time)
		{
			low = mid;
		}
		else
		{
			high = mid;
		}
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

	uint stride       = self.stride;
	bool spline       = self.interp == gltf::Interpolation.CUBICSPLINE;
	// CUBICSPLINE stores [in-tangent, value, out-tangent] per key, so the value
	// of key `k` is at `k * 3 * stride + stride`.
	uint block        = spline ? stride * 3 : stride;
	uint value_offset = spline ? stride : 0;

	float fraction;
	usz key  = find_keyframe(self.times, time, &fraction);
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
		float t    = fraction;
		float t2   = t * t;
		float t3   = t2 * t;

		float h00 =  2 * t3 - 3 * t2 + 1;
		float h10 =  t3 - 2 * t2 + t;
		float h01 = -2 * t3 + 3 * t2;
		float h11 =  t3 - t2;

		// The out-tangent of the earlier key and the in-tangent of the later one,
		// both scaled by the interval — glTF stores tangents per unit of the
		// *parameter*, and the parameter here is seconds.
		usz out_tangent = key * (usz)block + (usz)stride * 2;
		usz in_tangent  = next * (usz)block;

		for (uint i = 0; i < stride; i++)
		{
			out[i] = h00 * self.values[a + i] + h10 * span * self.values[out_tangent + i] + h01 * self.values[b + i]
				+ h11 * span * self.values[in_tangent + i];
		}
		if (self.path == AnimatedPath.ROTATION) normalize_into(out);
		return;
	}

	if (self.path == AnimatedPath.ROTATION)
	{
		Quaternionf from  = { self.values[a], self.values[a + 1], self.values[a + 2], self.values[a + 3] };
		Quaternionf to    = { self.values[b], self.values[b + 1], self.values[b + 2], self.values[b + 3] };
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
 The most clips one character blends at once.

 Four is a walk, a run, the jump a landing is still coming out of, and one to
 spare for the idle a stop fades into — what a locomotion graph asks for at any
 one moment. Fixed rather than a list because a player is per character, and a
 hundred of them stay a hundred structs.
*>
const uint ANIMATION_LAYERS = 4;

<*
 One clip on a character's stack: its clock, and how much of the picture it is.

 `weight` moves toward `target` at `rate` per second, which is the whole of a
 fade — `play(name, { fade })` raises one layer and lowers the rest so they all
 arrive together, and `Scene.blend` sets several targets at once. A layer whose
 weight and target are both zero is gone at the end of the frame.
*>
struct AnimationLayer
{
	// Into the asset's clips.
	int clip;
	// In the clip's own units, which begin at `clip.start`.
	float time;
	float speed;
	bool loop;
	bool playing;
	float weight;
	float target;
	// Weight per second toward `target`; zero or less arrives at once.
	float rate;
	// Cycles on from the player's shared `phase`, or negative for a layer on its
	// own clock.
	float offset;
}

<*
 One node's share of every layer that drives it, summed before it is written.

 A rotation is summed as a 4-vector, each sample turned into the same hemisphere
 as the node's rest rotation first, and normalised once at the end — the
 weighted mean of several rotations, which for two at equal weight is exactly the
 slerp half-way.
*>
struct LayerSum
{
	Vec3 position;
	float position_weight;
	Quaternionf rotation;
	float rotation_weight;
	Vec3 scale;
	float scale_weight;
	bool touched;
	bool morphed;
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

	<*
	 The clips this character is blending, in the order they arrived, and how many.
	 Empty is the state a player spends most of its life in, and is not the same as
	 "no player".

	 **Symmetric by construction.** Every node any layer drives starts each frame
	 from the file's rest pose and takes Σ wᵢ·sampleᵢ over the layers that drive it,
	 the rest of the weight staying rest — so a node only a leaving clip moved goes
	 back where the file had it, as the baked table always did, and a third clip
	 asked for mid-fade joins the other two instead of dropping one.
	*>
	AnimationLayer[ANIMATION_LAYERS] layers;
	uint layer_count;

	<*
	 The shared cycle of every phase-locked layer, in [0, 1), and whether there is
	 one.

	 A walk and a run blended by speed have different lengths, so two clocks drift
	 and the feet cross. Locked layers share this one instead: it advances at the
	 weighted mean of their own rates, and each reads its time as
	 `start + frac(phase + offset) · duration` — the walk's left foot lands on the
	 run's left foot whatever the mix.
	*>
	double phase;
	bool phased;

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

	<*
	 What a baked character blending more than one clip is posed from, on the CPU.

	 The table holds one clip a frame, and a crossfade between two of them used to
	 be a per-vertex mix of joint matrices in the shader — not rigid, and no way to
	 hold three. So while more than one layer has weight, `blend_layers` samples
	 each into the asset's own hierarchy, mixes the transforms, composes the joints
	 and writes `palette` here, every skinned target's joints in a row, which
	 `MeshPass.write_live_poses` uploads like a live skeleton's. One clip at full
	 weight goes back to the table and costs one uint again.
	*>
	bool composed;
	List{PosedNode} posed;
	List{LayerSum} sums;
	List{Matrix4f} locals;
	List{Matrix4f} world;
	List{Matrix4f} palette;
}

fn void AnimationPlayer.free(&self)
{
	self.targets.free();
	self.targets = { };
	self.skinned.free();
	self.skinned = { };
	self.weight_scratch.free();
	self.weight_scratch = { };
	self.posed.free();
	self.posed = { };
	self.sums.free();
	self.sums = { };
	self.locals.free();
	self.locals = { };
	self.world.free();
	self.world = { };
	self.palette.free();
	self.palette = { };
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

 A player whose clocks have all stopped and whose weights have all arrived has
 nothing to write, and writes nothing — which is what lets a held pose cost
 nothing and lets the window sleep.
*>
fn void AnimationPlayer.advance(&self, Scene* scene, Assets* assets, float dt)
{
	if (!self.active()) return;

	Asset* owner = assets.slot(self.asset);
	if (owner == null)
	{
		self.layer_count = 0;
		self.phased = false;
		return;
	}

	self.step_clocks(owner, dt);
	self.step_weights(dt);
	self.pose(scene, owner);
	// The frame a fade ends on is posed with the leaving layer still in it, at
	// nothing, which is what puts its nodes back at rest. If that leaves one clip
	// at the whole of the picture, it is posed again as one — back on the table
	// this frame rather than composed for one more.
	if (self.drop_silent() && self.layer_count == 1) self.pose(scene, owner);
}

<*
 Whether anything about this player moves this frame: a clock running, or a
 weight on its way somewhere.
*>
fn bool AnimationPlayer.active(&self)
{
	for (uint i = 0; i < self.layer_count; i++)
	{
		AnimationLayer* layer = &self.layers[i];
		if (layer.playing || layer.weight != layer.target) return true;
	}
	return false;
}

<*
 The layer the character is heading for: the highest target, the heaviest of
 those, the newest of those. -1 when the stack is empty.

 By target first, because what a script asks about is the clip it asked for —
 `play('jump', { fade })` and then `animation.name` is `'jump'` from that frame
 on, not the walk it is still mostly showing — and because that is also what a
 `sync` lines up with. A held blend's heaviest clip is the one with the highest
 target anyway.
*>
fn int AnimationPlayer.dominant(&self)
{
	int best = -1;
	for (uint i = 0; i < self.layer_count; i++)
	{
		AnimationLayer* layer = &self.layers[i];
		if (best < 0) { best = (int)i; continue; }
		AnimationLayer* held = &self.layers[best];
		if (layer.target != held.target)
		{
			if (layer.target > held.target) best = (int)i;
			continue;
		}
		if (layer.weight >= held.weight) best = (int)i;
	}
	return best;
}

<*
 A layer of this clip whose clock is running, preferring the one rising — which
 is what makes asking for a clip already playing a no-op rather than a second
 copy. -1 when there is none, including a held one: asking for that one again is a
 restart, faded out of where it stopped.
*>
fn int AnimationPlayer.playing_layer(&self, int clip)
{
	int found = -1;
	for (uint i = 0; i < self.layer_count; i++)
	{
		AnimationLayer* layer = &self.layers[i];
		if (layer.clip != clip || !layer.playing) continue;
		if (found < 0 || layer.target > self.layers[found].target) found = (int)i;
	}
	return found;
}

<*
 A fresh layer at weight zero, its fields for the caller to fill.

 A full stack makes room by dropping its lightest layer — the one that was
 leaving anyway, almost always, so what that costs is a few percent of a pose
 rather than a pop.
*>
fn uint AnimationPlayer.add_layer(&self, int clip)
{
	if (self.layer_count >= ANIMATION_LAYERS)
	{
		uint lightest = 0;
		for (uint i = 1; i < self.layer_count; i++)
		{
			AnimationLayer* layer = &self.layers[i];
			AnimationLayer* held = &self.layers[lightest];
			if (layer.weight + layer.target < held.weight + held.target) lightest = i;
		}
		self.remove_layer(lightest);
	}
	uint at = self.layer_count++;
	self.layers[at] = { .clip = clip, .speed = 1, .loop = true, .playing = true, .offset = -1 };
	return at;
}

fn void AnimationPlayer.remove_layer(&self, uint at)
{
	for (uint i = at; i + 1 < self.layer_count; i++) self.layers[i] = self.layers[i + 1];
	self.layer_count--;
}

<*
 Raises one layer to the whole of the picture over `fade` seconds and lowers
 every other so they all arrive together.

 The one rising goes at a constant 1/fade, so turning back to a clip that was
 three quarters gone takes three quarters of the fade, not a whole one; the rest
 fall in proportion to what they hold, so the weights keep summing to one the
 whole way and no frame of the transition shows the rest pose through it.
*>
fn void AnimationPlayer.raise(&self, uint at, float fade)
{
	AnimationLayer* up = &self.layers[at];
	float span = (1.0f - up.weight) * fade;
	up.target = 1.0f;
	up.rate = fade > 0 ? 1.0f / fade : 0;
	for (uint i = 0; i < self.layer_count; i++)
	{
		if (i == at) continue;
		AnimationLayer* down = &self.layers[i];
		down.target = 0;
		down.rate = span > 0 ? down.weight / span : 0;
	}
}

<*
 Every running clock, stepped by `dt`.

 A phase-locked layer reads its time off the shared cycle rather than its own
 clock, and the cycle advances at the weighted mean rate of the locked layers —
 a walk at 1.05 s and a run at 0.67 s, half and half, go round once every
 0.82 s, and both are at the same point of their stride the whole way.
*>
fn void AnimationPlayer.step_clocks(&self, Asset* owner, float dt)
{
	if (self.phased)
	{
		double rate = 0;
		double weight = 0;
		for (uint i = 0; i < self.layer_count; i++)
		{
			AnimationLayer* layer = &self.layers[i];
			if (layer.offset < 0 || !layer.playing || layer.clip < 0 || layer.clip >= owner.clips.len()) continue;
			AnimationClip* clip = &owner.clips[layer.clip];
			if (clip.duration <= 0) continue;
			// The weight it is heading for as well as the one it has, so a lock
			// faded in from nothing does not stall the cycle on its first frame.
			float w = layer.weight > layer.target ? layer.weight : layer.target;
			rate += (double)w * layer.speed / clip.duration;
			weight += w;
		}
		if (weight > 0)
		{
			self.phase += dt * rate / weight;
			self.phase -= math::floor(self.phase);
		}
	}

	for (uint i = 0; i < self.layer_count; i++)
	{
		AnimationLayer* layer = &self.layers[i];
		if (!layer.playing || layer.clip < 0 || layer.clip >= owner.clips.len()) continue;
		AnimationClip* clip = &owner.clips[layer.clip];
		if (self.phased && layer.offset >= 0 && clip.duration > 0)
		{
			double at = self.phase + layer.offset;
			at -= math::floor(at);
			layer.time = clip.start + (float)(at * clip.duration);
			continue;
		}
		layer.time = step_time(clip, layer.time, layer.speed, layer.loop, dt, &layer.playing);
	}
}

<*
 Sends a layer to nothing over `fade` seconds — unless it is on its way there
 already, when it keeps the rate it set out at.

 What makes a blend asked for every frame let go of a clip at all. Re-aimed each
 frame at `weight / fade`, a leaving layer covers the same fraction of what is left
 every frame and never arrives: an idle a walk was blended out of stayed on the
 stack at a ten-thousandth for as long as the walk lasted, and kept the character
 composed on the CPU the whole time.
*>
fn void AnimationPlayer.let_go(&self, AnimationLayer* layer, float fade)
{
	if (layer.target <= 0 && layer.rate > 0) return;
	layer.target = 0;
	layer.rate = fade > 0 ? layer.weight / fade : 0;
}

<*
 The player's scratch lists on the heap, before anything grows them — see
 `blend_layers` for the pool that took them otherwise.
*>
fn void AnimationPlayer.own_scratch(&self, sz nodes)
{
	if (self.sums.allocator == null) self.sums.init(mem, nodes);
	if (self.posed.allocator == null) self.posed.init(mem, nodes);
	if (self.locals.allocator == null) self.locals.init(mem, nodes);
	if (self.world.allocator == null) self.world.init(mem, nodes);
	if (self.palette.allocator == null) self.palette.init(mem, 64);
}

<*
 Every phase-locked layer put at its point of the shared cycle now, rather than at
 the next step — so a clip that has just joined a lock is in step on the frame it
 joined.
*>
fn void AnimationPlayer.place_locked(&self, Asset* owner)
{
	if (!self.phased) return;
	for (uint i = 0; i < self.layer_count; i++)
	{
		AnimationLayer* layer = &self.layers[i];
		if (layer.offset < 0 || layer.clip < 0 || layer.clip >= owner.clips.len()) continue;
		AnimationClip* clip = &owner.clips[layer.clip];
		if (clip.duration <= 0) continue;
		double at = self.phase + layer.offset;
		at -= math::floor(at);
		layer.time = clip.start + (float)(at * clip.duration);
	}
}

// Every weight moved toward its target by its rate.
fn void AnimationPlayer.step_weights(&self, float dt)
{
	for (uint i = 0; i < self.layer_count; i++)
	{
		AnimationLayer* layer = &self.layers[i];
		if (layer.weight == layer.target) continue;
		float step = layer.rate > 0 ? layer.rate * dt : 1e30f;
		if (layer.weight < layer.target)
		{
			layer.weight = layer.weight + step >= layer.target ? layer.target : layer.weight + step;
		}
		else
		{
			layer.weight = layer.weight - step <= layer.target ? layer.target : layer.weight - step;
		}
	}
}

<*
 Layers that have faded all the way out, gone — after the frame they reached
 zero on was written, so that frame put their nodes back at rest.
*>
fn bool AnimationPlayer.drop_silent(&self)
{
	uint was = self.layer_count;
	for (uint i = self.layer_count; i > 0; i--)
	{
		AnimationLayer* layer = &self.layers[i - 1];
		if (layer.weight <= 0 && layer.target <= 0) self.remove_layer(i - 1);
	}
	bool locked = false;
	for (uint i = 0; i < self.layer_count; i++) locked = locked || self.layers[i].offset >= 0;
	self.phased = self.phased && locked;
	return self.layer_count != was;
}

<*
 Every layer's nodes back to the file's rest pose — what a snap does to the clips
 it replaces, so a node only they drove does not keep their last pose forever.
*>
fn void AnimationPlayer.reset_layers(&self, Scene* scene, Asset* owner)
{
	for (uint i = 0; i < self.layer_count; i++)
	{
		AnimationLayer* layer = &self.layers[i];
		if (layer.clip < 0 || layer.clip >= owner.clips.len()) continue;
		self.reset_targets(scene, owner, &owner.clips[layer.clip]);
	}
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
 The stack written into the nodes, and into the skin.

 One clip at the whole of the picture is the plain write it always was — exact,
 and leaving every node the clip does not drive alone. Anything else is
 `blend_layers`.
*>
fn void AnimationPlayer.pose(&self, Scene* scene, Asset* owner)
{
	if (self.layer_count == 0) return;
	AnimationLayer* only = &self.layers[0];
	if (self.layer_count == 1 && only.weight >= 1.0f && only.clip >= 0 && only.clip < owner.clips.len())
	{
		self.write_clip(scene, &owner.clips[only.clip], only.time, 1.0f);
		self.composed = false;
	}
	else
	{
		self.blend_layers(scene, owner);
	}
	self.key_pose(scene, owner);
}

<*
 Every layer mixed into the nodes by its weight, the rest of the weight rest.

 The weights are taken as they are while they sum to one or less — a lone layer at
 0.3 is three tenths of a clip over the rest pose, which is what Three.js's mixer
 does too — and normalised when they sum past it. The pose is built in the asset's
 own hierarchy first (`posed`), so the same numbers go to whichever nodes this
 instance has *and* to the palette of a baked character, whose bones it does not.
*>
fn void AnimationPlayer.blend_layers(&self, Scene* scene, Asset* owner)
{
	sz nodes = owner.nodes.len();
	// Every list on the player is given the heap before it first grows. A list left
	// to initialise itself takes whichever allocator is current at its first push,
	// and the first push is often inside a binding's `@pool` — a `blend` from a
	// script — so its storage was temporary and the pool freed it under the player.
	self.own_scratch(nodes);
	while (self.sums.len() < nodes) self.sums.push({ });
	while (self.posed.len() < nodes) self.posed.push({ });
	foreach (&sum : self.sums.array_view()[:nodes]) *sum = { };

	float total = 0;
	for (uint i = 0; i < self.layer_count; i++) if (self.layers[i].weight > 0) total += self.layers[i].weight;
	float norm = total > 1.0f ? 1.0f / total : 1.0f;

	float[4] value;
	for (uint i = 0; i < self.layer_count; i++)
	{
		AnimationLayer* layer = &self.layers[i];
		float w = layer.weight * norm;
		if (layer.clip < 0 || layer.clip >= owner.clips.len()) continue;
		AnimationClip* clip = &owner.clips[layer.clip];
		foreach (&channel : clip.channels)
		{
			if (channel.node >= nodes) continue;
			LayerSum* sum = &self.sums[channel.node];
			// Every node a layer drives is written, at nothing as well: the frame a
			// layer fades out on is the frame its nodes go back to rest, and a node
			// skipped then would keep the clip's last pose.
			if (channel.path == AnimatedPath.WEIGHTS)
			{
				sum.morphed = true;
				continue;
			}
			sum.touched = true;
			if (w <= 0) continue;
			channel.sample(layer.time, value[..]);
			switch (channel.path)
			{
				case AnimatedPath.TRANSLATION:
					sum.position += (Vec3){ value[0], value[1], value[2] } * w;
					sum.position_weight += w;
				case AnimatedPath.ROTATION:
					Quaternionf q = { value[0], value[1], value[2], value[3] };
					if (q.v.dot(owner.nodes[channel.node].rotation.v) < 0) q = -q;
					sum.rotation.v += q.v * w;
					sum.rotation_weight += w;
				case AnimatedPath.SCALE:
					sum.scale += (Vec3){ value[0], value[1], value[2] } * w;
					sum.scale_weight += w;
				default:
					break;
			}
		}
	}

	// Rest for every node, and the sums over it for the ones a layer drives.
	foreach (n, &posed : self.posed.array_view()[:nodes])
	{
		AssetNode* rest = &owner.nodes[n];
		*posed = { .position = rest.position, .rotation = rest.rotation, .scale = rest.scale };
		LayerSum* sum = &self.sums[n];
		if (!sum.touched) continue;
		if (sum.position_weight > 0)
		{
			posed.position = sum.position + rest.position * (1.0f - sum.position_weight);
		}
		if (sum.rotation_weight > 0)
		{
			Quaternionf mixed = { .v = sum.rotation.v + rest.rotation.v * (1.0f - sum.rotation_weight) };
			if (mixed.v.length() > 1e-6f) posed.rotation = mixed.normalize();
		}
		if (sum.scale_weight > 0)
		{
			posed.scale = sum.scale + rest.scale * (1.0f - sum.scale_weight);
		}

		if (n >= self.targets.len()) continue;
		NodeId id = self.targets[n];
		if (!id.is_set()) continue;
		Node* node = scene.node(id);
		if (node == null) continue;
		node.position = posed.position;
		node.rotation = posed.rotation;
		node.scale = posed.scale;
		scene.mark_moved(id);
	}

	// Morph weights rest at zero, so the rest's share adds nothing and each layer's
	// sample simply adds in at its weight.
	for (uint i = 0; i < self.layer_count; i++)
	{
		AnimationLayer* layer = &self.layers[i];
		float w = layer.weight * norm;
		if (layer.clip < 0 || layer.clip >= owner.clips.len()) continue;
		AnimationClip* clip = &owner.clips[layer.clip];
		foreach (&channel : clip.channels)
		{
			if (channel.path != AnimatedPath.WEIGHTS || channel.node >= nodes) continue;
			if (channel.node >= self.targets.len()) continue;
			NodeId id = self.targets[channel.node];
			if (!id.is_set()) continue;
			LayerSum* sum = &self.sums[channel.node];
			if (sum.morphed)
			{
				// First time this frame: the rest, which is no expression at all.
				scene.clear_morph_weights(id);
				sum.morphed = false;
			}
			if (w > 0) self.add_weights(scene, channel, id, layer.time, w);
		}
	}

	// A baked character's palette, which the table cannot hold for a mix.
	self.composed = false;
	if (self.live_skin || self.skinned.len() == 0 || owner.skins.len() == 0) return;
	while (self.locals.len() < nodes) self.locals.push(matrix::IDENTITY4{float});
	while (self.world.len() < nodes) self.world.push(matrix::IDENTITY4{float});
	owner.compose_posed(self.posed.array_view()[:nodes], self.locals.array_view()[:nodes], self.world.array_view()[:nodes]);

	sz joints = 0;
	foreach (&target : self.skinned)
	{
		if (target.skin < owner.skins.len()) joints += owner.skins[target.skin].joints.len();
	}
	while (self.palette.len() < joints) self.palette.push(matrix::IDENTITY4{float});
	sz at = 0;
	foreach (&target : self.skinned)
	{
		if (target.skin >= owner.skins.len()) continue;
		sz count = owner.skins[target.skin].joints.len();
		owner.skin_joints(target.skin, self.world.array_view()[:nodes], self.palette.array_view()[at:count]);
		at += count;
	}
	self.composed = true;
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
 Points every skinned mesh under this player at the two baked frames either side
 of the dominant layer's time, and how far between them it is — when one clip is
 all of the picture.

 The whole of what posing a baked character costs: a divide, a floor, a clamp and
 three stores per skinned mesh. No matrices are touched and nothing is uploaded;
 the shader blends the two frames (`blend_frames`), so a clip sampled thirty times
 a second plays smoothly at any rate, slowed right down included.

 A composed character — more than one layer with weight — is not keyed at all:
 `MeshPass.write_live_poses` points it at the palette `blend_layers` wrote.

 A skin the asset never baked — the buffer failed, or the file has clips and no
 skeleton — leaves `pose` where `Scene.set_skin` put it, which is the rest pose.
*>
fn void AnimationPlayer.key_pose(&self, Scene* scene, Asset* owner)
{
	if (self.skinned.len() == 0 || self.layer_count == 0) return;
	// A live character's offset is written by `MeshPass.write_live_poses` from
	// the bone nodes `apply` has just posed. Keying a baked frame on top would be
	// two writers for one field, and which one won would depend on call order.
	if (self.live_skin) return;

	int top = self.dominant();
	if (top < 0) return;
	AnimationLayer* layer = &self.layers[top];
	if (layer.clip < 0 || layer.clip >= owner.clips.len()) return;
	AnimationClip* clip = &owner.clips[layer.clip];

	foreach (&target : self.skinned)
	{
		Node* node = scene.node(target.node);
		if (node == null) continue;
		node.pose_next = 0;
		node.pose_t = 0;
		if (self.composed) continue;

		BakedPose* segment = owner.segment(target.skin, (uint)layer.clip);
		if (segment == null) continue;

		float position = (layer.time - clip.start) * segment.fps;
		if (position < 0) position = 0;
		int frame = (int)math::floor(position);
		float between = position - (float)frame;
		// Within a hair of a frame is that frame: four fetches a vertex rather than
		// eight for a difference no pixel shows, and a clip that ends exactly on its
		// last key lands on it rather than a ten-thousandth short.
		if (between > 0.9999f) { frame++; between = 0; }
		if (between < 0.0001f) between = 0;
		// The last frame has no next: a one-shot held at its end, or a loop on its
		// seam, which `plan_segments` made the same pose as the first.
		int last = (int)segment.frame_count - 1;
		if (frame >= last) { frame = last; between = 0; }

		node.pose = segment.frame_at(frame);
		node.pose_next = between > 0 ? segment.frame_at(frame + 1) : node.pose;
		node.pose_t = between;
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
				node.rotation = mix_quat(
					node.rotation,
					(Quaternionf) { value[0], value[1], value[2], value[3] },
					weight
				);
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
	self.pose(scene, owner);
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

	if (self.weight_scratch.allocator == null) self.weight_scratch.init(mem, channel.stride);
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
 One WEIGHTS channel's sample, added into the node's morph weights at `weight`.

 The blend's half of `write_weights`: a morph weight rests at zero, so a mix of
 layers is the sum of their weighted samples and the rest contributes nothing.
*>
fn void AnimationPlayer.add_weights(&self, Scene* scene, AnimationChannel* channel, NodeId id, float time, float weight)
{
	uint targets = scene.morph_target_count(id);
	if (targets == 0 || channel.stride == 0) return;

	if (self.weight_scratch.allocator == null) self.weight_scratch.init(mem, channel.stride);
	while (self.weight_scratch.len() < channel.stride) self.weight_scratch.push(0);
	channel.sample(time, self.weight_scratch.array_view());

	uint count = channel.stride < targets ? channel.stride : targets;
	float[] current = scene.morph_weights(id);
	for (uint i = 0; i < count; i++)
	{
		float was = i < current.len ? current[i] : 0;
		self.weight_scratch[i] = was + self.weight_scratch[i] * weight;
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