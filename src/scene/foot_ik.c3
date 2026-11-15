<*
 Feet on the ground: a ray under each animated foot, the pelvis lowered for the
 lower one, a two-bone solve per leg and the foot turned to the slope.

 A walk is authored on a flat floor, and a capsule is the wrong thing to place
 feet with — it rests on its skin and on the side of its hemisphere. So the
 character is drawn where the controller says, posed by its clip, and then this
 bends each leg so its foot meets the ground the clip did not know about. Two rays
 and two closed-form solves a character, which is why it is for heroes and not for
 crowds: a crowd is too far away to see its feet.

 ## Where it runs, and why there

 After the clips (`step_animations`) and after every frame system — the system
 that moves the character is one of them, and a `play()` re-poses the bones — and
 before the draw computes the live palette from the bone nodes. See
 `JsRuntime.solve_foot_ik`.

 It updates only each character's own world matrices, and casts without re-filing
 the query index — both would otherwise walk the whole scene, which on a level is
 nine tenths of the cost. A moving floor is seen a frame late.

 ## It writes bone nodes, so it must not compound

 A held clip, a paused clock and a stopped player do not re-pose anything, and a
 solve that started from its own last answer would bend a knee further every
 frame. So every channel it touches keeps what was there before it wrote (the
 source) and what it wrote. A channel still holding exactly what it wrote was not
 re-posed, and is put back before solving; anything else is new and becomes the
 source.

 Uniform scale is assumed along each leg: rotations are read off world matrices.
*>
module three;

import std::math;
import std::math::quaternion;
import std::time;
import collision;

// Two for a person, four for anything that walks on all of them.
const uint FOOT_IK_LEGS = 4;

struct FootIkBone
{
	NodeId node;
	Vec3 source_position;
	Quaternionf source_rotation;
	Vec3 written_position;
	Quaternionf written_rotation;
	bool wrote;
}

struct FootIkLeg
{
	FootIkBone upper;
	FootIkBone lower;
	FootIkBone foot;

	// The ankle's height over the sole standing still, in the root's units.
	float ankle;

	// Smoothed: how far the ankle is moved up (world units), the ground's normal
	// under it, and how planted the foot is (1 standing, 0 in the swing).
	float offset;
	Vec3 normal;
	float plant;
}

struct FootIkRig
{
	NodeId root;
	uint serial;
	FootIkBone pelvis;
	FootIkLeg[FOOT_IK_LEGS] legs;
	uint leg_count;

	// In the root's units, so a character scaled later keeps its proportions.
	float reach;
	// Radians.
	float tilt;
	// Seconds; zero is no smoothing.
	float smooth;

	float weight;
	bool enabled;

	// Nothing written and nothing owed: weight zero and settled, or switched off.
	bool rested;
}

<*
 What the foot IK did since the last host tick — `three.stats().footIk`.
*>
struct FootIkCounters
{
	// Rigs solved, legs solved, rays cast and rays that found no ground.
	uint rigs;
	uint solves;
	uint rays;
	uint misses;
	// Wall time of the whole pass, microseconds.
	float us;
}

<*
 World-space turns for a two-bone limb: the upper bone's, and the lower bone's
 (which includes the upper's, since it hangs from it).
*>
struct TwoBoneTurns
{
	Quaternionf upper;
	Quaternionf lower;
}

<*
 The angle between two vectors of any length, by atan2 — `acos` of a dot has no
 precision left near zero, which is where a planted foot's corrections live.
*>
fn float angle_between(Vec3 u, Vec3 v) @local
{
	return math::atan2(u.cross(v).length(), u.dot(v));
}

<*
 The turns that bring the end `c` of the limb `a`→`b`→`c` to `target`.

 Closed form: the law of cosines gives the two interior angles a limb of these
 lengths needs to span the distance, the knee bends in the plane it is already
 bent in, and the whole limb then swings onto the target. Bend first, then swing:
 bending at both joints by those angles keeps the direction from `a` to `c`, so
 the swing measured before the bend is still the right one after it.

 `pole` is where a straight limb bends toward — it has no bend plane of its own.
 A target past reach straightens the limb along the line to it.
*>
fn TwoBoneTurns solve_two_bone(Vec3 a, Vec3 b, Vec3 c, Vec3 target, Vec3 pole)
{
	const float EPS = 1e-5f;
	TwoBoneTurns none = { quaternion::IDENTITY, quaternion::IDENTITY };

	float lab = (b - a).length();
	float lcb = (c - b).length();
	if (lab < EPS || lcb < EPS) return none;

	Vec3 ac  = c - a;
	Vec3 at  = target - a;
	float lat = math::clamp(at.length(), math::max(math::abs(lab - lcb), EPS) + EPS, lab + lcb - EPS);

	float ac_ab_0 = angle_between(ac, b - a);
	float ba_bc_0 = angle_between(a - b, c - b);
	float ac_at_0 = angle_between(ac, at);

	float ac_ab_1 = math::acos(math::clamp((lcb * lcb - lab * lab - lat * lat) / (-2.0f * lab * lat), -1.0f, 1.0f));
	float ba_bc_1 = math::acos(math::clamp((lat * lat - lab * lab - lcb * lcb) / (-2.0f * lab * lcb), -1.0f, 1.0f));

	// The plane the knee is bent in now; for a straight limb, the pole's.
	Vec3 axis0 = ac.cross(b - a);
	if (axis0.length() < 1e-4f * lab * lcb) axis0 = ac.cross(pole);
	if (axis0.length() < 1e-9f) axis0 = collision::any_perpendicular(ac.normalize());
	axis0 = axis0.normalize();

	Quaternionf r0 = quaternion::from_axis_angle(axis0, ac_ab_1 - ac_ab_0);
	Quaternionf r1 = quaternion::from_axis_angle(axis0, ba_bc_1 - ba_bc_0);

	Quaternionf r2 = quaternion::IDENTITY;
	Vec3 axis1     = ac.cross(at);
	if (axis1.length() > 1e-9f) r2 = quaternion::from_axis_angle(axis1.normalize(), ac_at_0);

	return { (r2 * r0).normalize(), (r2 * r1 * r0).normalize() };
}

// Exact, on purpose: "is this still what I wrote" is a question about bits.
fn bool same_rotation(Quaternionf a, Quaternionf b) @local
{
	return a.v.x == b.v.x && a.v.y == b.v.y && a.v.z == b.v.z && a.v.w == b.v.w;
}

fn bool same_position(Vec3 a, Vec3 b) @local => a.x == b.x && a.y == b.y && a.z == b.z;

<*
 Takes this frame's source for one bone: puts back what was there before the
 last write if nothing has re-posed it since, and adopts the new pose if
 something has.
*>
fn void Scene.take_source(&self, FootIkBone* bone, bool position)
{
	Node* node = self.node(bone.node);
	if (node == null) return;

	if (!bone.wrote)
	{
		bone.source_rotation = node.rotation;
		bone.source_position = node.position;
		return;
	}

	bool rotation_kept = same_rotation(node.rotation, bone.written_rotation);
	bool position_kept = !position || same_position(node.position, bone.written_position);
	bool restored      = false;

	if (rotation_kept)
	{
		node.rotation = bone.source_rotation;
		restored      = true;
	}
	else
	{
		bone.source_rotation = node.rotation;
	}

	if (position)
	{
		if (position_kept)
		{
			node.position = bone.source_position;
			restored      = true;
		}
		else
		{
			bone.source_position = node.position;
		}
	}
	else
	{
		bone.source_position = node.position;
	}

	bone.wrote = false;
	if (restored) self.mark_moved(bone.node);
}

fn void Scene.rig_take_sources(&self, FootIkRig* rig)
{
	self.take_source(&rig.pelvis, true);
	for (uint i = 0; i < rig.leg_count; i++)
	{
		self.take_source(&rig.legs[i].upper, false);
		self.take_source(&rig.legs[i].lower, false);
		self.take_source(&rig.legs[i].foot, false);
	}
}

fn void Scene.write_rotation(&self, FootIkBone* bone, Quaternionf local)
{
	Node* node = self.node(bone.node);
	if (node == null) return;
	node.rotation           = local;
	bone.written_rotation   = local;
	bone.written_position   = node.position;
	bone.wrote              = true;
	self.mark_moved(bone.node);
}

// A node's world rotation, scale divided out.
fn Quaternionf Scene.world_rotation(&self, NodeId id)
{
	Node* node = self.node(id);
	if (node == null) return quaternion::IDENTITY;
	Vec3 position;
	Quaternionf rotation;
	Vec3 scale;
	decompose(node.world, &position, &rotation, &scale);
	return rotation;
}

fn Quaternionf Scene.parent_rotation(&self, NodeId id)
{
	Node* node = self.node(id);
	if (node == null || !node.parent.is_set()) return quaternion::IDENTITY;
	return self.world_rotation(node.parent);
}

fn float Scene.world_scale_y(&self, NodeId id)
{
	Node* node = self.node(id);
	if (node == null) return 1.0f;
	float s = ((Vec3) { node.world.m[4], node.world.m[5], node.world.m[6] }).length();
	return s > 1e-8f ? s : 1.0f;
}

fn bool Scene.is_child_of(&self, NodeId child, NodeId parent)
{
	Node* node = self.node(child);
	return node != null && node.parent == parent;
}

fn bool Scene.is_ancestor(&self, NodeId ancestor, NodeId of)
{
	Node* node = self.node(of);
	while (node != null && node.parent.is_set())
	{
		if (node.parent == ancestor) return true;
		node = self.node(node.parent);
	}
	return false;
}

<*
 Puts a character's legs on the ground every frame — see the module comment.

 `legs` is three bones a leg, upper, lower and foot, each the parent of the next.
 Replaces a rig already on `root`, putting its bones back first.

 @param legs : "Three nodes a leg: upper, lower, foot"
 @param reach : "World units: the most a foot is moved, and the most the pelvis drops"
 @param tilt_degrees : "The most a planted foot is turned toward the slope"
 @param smooth : "Seconds; zero snaps"
 @param ankle : "World units of ankle over sole; zero or less measures the current pose"
 @param [&out] serial : "What later calls name this rig by"
 @require legs.len % 3 == 0 : "Three bones a leg"

 @return "False when the root is not a live skeleton, or the bones are not a leg"
*>
fn bool Scene.add_foot_rig(
	&self,
	NodeId root,
	NodeId pelvis,
	NodeId[] legs,
	float reach,
	float tilt_degrees,
	float smooth,
	float ankle,
	float weight,
	uint* serial
)
{
	usz count = legs.len / 3;
	if (count == 0 || count > FOOT_IK_LEGS) return false;

	AnimationPlayer* player = self.player(root);
	if (player == null || !player.live_skin) return false;
	if (self.node(pelvis) == null || !self.is_ancestor(root, pelvis)) return false;

	for (usz i = 0; i < count; i++)
	{
		NodeId upper = legs[i * 3];
		NodeId lower = legs[i * 3 + 1];
		NodeId foot  = legs[i * 3 + 2];
		if (self.node(upper) == null || self.node(lower) == null || self.node(foot) == null) return false;
		if (!self.is_child_of(lower, upper) || !self.is_child_of(foot, lower)) return false;
		if (!self.is_ancestor(pelvis, upper)) return false;
	}

	self.remove_foot_rig(root, 0);

	self.update_world_matrices();
	Node* root_node = self.node(root);
	float scale     = self.world_scale_y(root);
	float root_y    = translation_of(root_node.world).y;

	FootIkRig rig = {
		.root = root,
		.serial = ++self.foot_ik_serial,
		.pelvis = { .node = pelvis },
		.leg_count = (uint)count,
		.reach = math::max(reach, 0.0f) / scale,
		.tilt = math::deg_to_rad(math::clamp(tilt_degrees, 0.0f, 89.0f)),
		.smooth = math::max(smooth, 0.0f),
		.weight = math::clamp(weight, 0.0f, 1.0f),
		.enabled = true,
	};
	for (usz i = 0; i < count; i++)
	{
		FootIkLeg* leg = &rig.legs[i];
		leg.upper  = { .node = legs[i * 3] };
		leg.lower  = { .node = legs[i * 3 + 1] };
		leg.foot   = { .node = legs[i * 3 + 2] };
		leg.normal = { 0, 1, 0 };
		float measured = translation_of(self.node(leg.foot.node).world).y - root_y;
		leg.ankle = (ankle > 0.0f ? ankle : math::max(measured, 1e-3f)) / scale;
	}

	self.foot_rigs.push(rig);
	*serial = rig.serial;
	return true;
}

fn FootIkRig* Scene.foot_rig(&self, NodeId root, uint serial)
{
	foreach (&rig : self.foot_rigs)
	{
		if (rig.root == root && (serial == 0 || rig.serial == serial)) return rig;
	}
	return null;
}

<*
 Sets a rig's weight and whether it runs. A stale serial is refused, so a handle
 to a rig that was replaced cannot reach the new one.

 @return "False when there is no such rig"
*>
fn bool Scene.set_foot_ik(&self, NodeId root, uint serial, float weight, bool enabled)
{
	FootIkRig* rig = self.foot_rig(root, serial);
	if (rig == null) return false;
	rig.weight  = math::clamp(weight, 0.0f, 1.0f);
	rig.enabled = enabled;
	if (enabled && rig.weight > 0.0f) rig.rested = false;
	if (!enabled) rig.rested = false;
	return true;
}

<*
 Takes a rig off its character, putting back the pose it was solving from.

 @param serial : "Zero for whichever rig is on the root"
 @return "False when there is no such rig"
*>
fn bool Scene.remove_foot_rig(&self, NodeId root, uint serial)
{
	for (sz i = 0; i < self.foot_rigs.len(); i++)
	{
		FootIkRig* rig = &self.foot_rigs[i];
		if (rig.root != root || (serial != 0 && rig.serial != serial)) continue;
		self.rig_take_sources(rig);
		self.foot_rigs.remove_at(i);
		return true;
	}
	return false;
}

<*
 Solves every rig for this frame. `dt` is game seconds; zero (paused) freezes the
 smoothing and still re-poses from the source, so a pause holds the same picture.
*>
fn void Scene.solve_foot_ik(&self, float dt)
{
	if (self.foot_rigs.len() == 0) return;
	Clock started = clock::now();

	// A character that died took its bones with it.
	for (sz i = self.foot_rigs.len(); i > 0; i--)
	{
		if (self.node(self.foot_rigs[i - 1].root) == null) self.foot_rigs.remove_at(i - 1);
	}

	bool active = false;
	foreach (&rig : self.foot_rigs)
	{
		if (rig.rested) continue;
		self.rig_take_sources(rig);
		if (!rig.enabled)
		{
			// Back on the clip, and nothing carried over to the day it is on again.
			for (uint i = 0; i < rig.leg_count; i++)
			{
				rig.legs[i].offset = 0;
				rig.legs[i].plant  = 0;
				rig.legs[i].normal = { 0, 1, 0 };
			}
			rig.rested = true;
			continue;
		}
		active = true;
	}
	if (!active)
	{
		self.foot_ik.us += (float)((long)started.to_now()) / 1000.0f;
		return;
	}

	// Each character's own bones, not the scene: the whole walk was nine tenths of
	// the pass on the Evil Forest, and the draw does it again afterwards anyway.
	foreach (&rig : self.foot_rigs)
	{
		if (rig.rested || !rig.enabled) continue;
		self.update_subtree_matrices(rig.root);
		self.solve_rig(rig, dt);
	}

	self.foot_ik.us += (float)((long)started.to_now()) / 1000.0f;
}

fn void Scene.solve_rig(&self, FootIkRig* rig, float dt)
{
	Node* root = self.node(rig.root);
	if (root == null) return;
	self.foot_ik.rigs++;

	float scale  = self.world_scale_y(rig.root);
	float reach  = rig.reach * scale;
	Vec3 root_at = translation_of(root.world);
	Vec3 up      = { 0, 1, 0 };
	float alpha  = rig.smooth > 0.0f ? 1.0f - math::exp(-dt / rig.smooth) : 1.0f;

	IgnoreSet skip;
	skip.nodes[0] = rig.root;
	skip.count    = 1;

	// Where each ankle has to go, smoothed.
	bool settled = rig.weight <= 0.0f;
	for (uint i = 0; i < rig.leg_count; i++)
	{
		FootIkLeg* leg = &rig.legs[i];
		Node* foot     = self.node(leg.foot.node);
		// A bone a script removed is a leg that is not there to solve.
		if (foot == null) return;
		Vec3 ankle_at  = translation_of(foot.world);
		float ankle    = leg.ankle * scale;
		float height   = ankle_at.y - root_at.y;

		float top            = math::max(ankle_at.y, root_at.y) + reach;
		collision::Ray ray   = { .origin = { ankle_at.x, top, ankle_at.z }, .direction = { 0, -1, 0 } };
		// Without re-filing what moved: that walks every world matrix in the scene,
		// and a ground box a frame old is not something a foot can show.
		Hit hit = self.raycast(self.assets, ray, true, skip, top - (root_at.y - reach), false);
		self.foot_ik.rays++;

		float target = 0.0f;
		Vec3 normal  = up;
		if (hit.hit)
		{
			normal = hit.normal.y < 0.0f ? -hit.normal : hit.normal;
			float ground = root_at.y + math::clamp(hit.point.y - root_at.y, -reach, reach);
			// Never below the ground: a clip that sinks a foot is lifted out of it.
			float stand  = math::max(height, ankle / math::max(normal.y, 0.5f));
			target = ground + stand - ankle_at.y;
		}
		else
		{
			self.foot_ik.misses++;
		}

		float lift  = height - ankle;
		float plant = math::clamp(1.0f - lift / math::max(ankle, 1e-3f), 0.0f, 1.0f);

		leg.offset += (target * rig.weight - leg.offset) * alpha;
		leg.plant  += (plant - leg.plant) * alpha;
		Vec3 blended = leg.normal + (normal - leg.normal) * alpha;
		leg.normal   = blended.length() > 1e-6f ? blended.normalize() : up;

		if (math::abs(leg.offset) > 1e-4f || leg.normal.y < 0.9999f) settled = false;
	}

	if (settled && rig.weight <= 0.0f)
	{
		// The clip's own pose is already back on the bones; nothing more to do
		// until somebody raises the weight.
		rig.rested = true;
		return;
	}

	// The pelvis comes down for the leg that has furthest to go down, so that leg
	// can reach; it never goes up, or a foot on a rise would hang the other one.
	float drop = 0.0f;
	for (uint i = 0; i < rig.leg_count; i++) drop = math::min(drop, rig.legs[i].offset);
	drop = math::max(drop, -reach);

	if (drop < 0.0f)
	{
		Node* pelvis = self.node(rig.pelvis.node);
		Node* parent = pelvis == null ? null : self.node(pelvis.parent);
		if (parent != null)
		{
			Vec3 local = transform_direction(invert(parent.world), (Vec3) { 0, drop, 0 });
			pelvis.position             = rig.pelvis.source_position + local;
			rig.pelvis.written_position = pelvis.position;
			rig.pelvis.written_rotation = pelvis.rotation;
			rig.pelvis.wrote            = true;
			self.mark_moved(rig.pelvis.node);
		}
	}

	Vec3 shift = { 0, drop, 0 };
	Vec3 pole  = transform_direction(root.world, (Vec3) { 0, 0, 1 });

	for (uint i = 0; i < rig.leg_count; i++)
	{
		FootIkLeg* leg = &rig.legs[i];
		Node* upper    = self.node(leg.upper.node);
		Node* lower    = self.node(leg.lower.node);
		Node* foot     = self.node(leg.foot.node);
		if (upper == null || lower == null || foot == null) continue;

		Vec3 a = translation_of(upper.world) + shift;
		Vec3 b = translation_of(lower.world) + shift;
		Vec3 c = translation_of(foot.world) + shift;
		Vec3 t = translation_of(foot.world) + (Vec3) { 0, leg.offset, 0 };

		TwoBoneTurns turns = solve_two_bone(a, b, c, t, pole);

		Quaternionf parent_q = self.parent_rotation(leg.upper.node);
		Quaternionf upper_q  = self.world_rotation(leg.upper.node);
		Quaternionf lower_q  = self.world_rotation(leg.lower.node);
		Quaternionf foot_q   = self.world_rotation(leg.foot.node);

		Quaternionf upper_new = (turns.upper * upper_q).normalize();
		Quaternionf lower_new = (turns.lower * lower_q).normalize();

		// The foot keeps the clip's world orientation rather than following the
		// shin, then turns toward the slope as far as it is standing on it.
		float limit  = rig.tilt * leg.plant * rig.weight;
		Vec3 axis    = up.cross(leg.normal);
		float angle  = math::min(angle_between(up, leg.normal), limit);
		Quaternionf tilt = axis.length() > 1e-6f && angle > 0.0f
			? quaternion::from_axis_angle(axis.normalize(), angle)
			: quaternion::IDENTITY;
		Quaternionf foot_new = (tilt * foot_q).normalize();

		self.write_rotation(&leg.upper, (parent_q.conjugate() * upper_new).normalize());
		self.write_rotation(&leg.lower, (upper_new.conjugate() * lower_new).normalize());
		self.write_rotation(&leg.foot, (lower_new.conjugate() * foot_new).normalize());
		self.foot_ik.solves++;
	}
}
