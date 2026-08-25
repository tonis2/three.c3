<*
 The character controller — `notes.md` §17, and §7's first entry before it was
 built.

 "Sweep, slide along the contact normal, step up ledges under a threshold,
 report `grounded`, the slope and what was hit. Otherwise every game rewrites
 the same 120 lines in JavaScript at 60 Hz."

 ## It is kinematic, and that is the whole design

 A character is not a rigidbody. A body the solver owns is pushed by contacts,
 tips over, slides down slopes it was asked to stand on, and answers "where am I"
 a frame late; a character has to go exactly where the input said, stop dead at a
 wall, and be standing still on a 30-degree slope with no friction tuned to make
 it so. Every engine that has tried to make one out of a rigidbody has ended up
 with a second code path anyway, and `notes.md`'s own note on
 `PHYSICS_OWNS_TRANSFORM` is the local version of the same argument: two things
 writing one transform is a fight, not a feature.

 So this touches the solver not at all. It sweeps a capsule against the *scene's*
 triangles through `scene/query.c3` and writes a position. A script that wants
 the character to push a crate calls `three.physics` for the crate.

 ## Move and slide, and the two things that are not obvious

 The loop is the ordinary one: sweep, stop at the contact, project what is left
 of the motion onto the contact plane, sweep again. Two parts of it are where the
 bugs live.

 **A ledge is climbed by three sweeps, not by a special case.** Up by the step
 height, across, then back down — and the climb is accepted only if the down
 sweep lands on something walkable. Written as an obstacle test ("is the thing in
 front of me shorter than my step?") it needs the obstacle's height, which a
 triangle soup does not have; written as three sweeps it needs nothing the
 controller does not already do, and it gets stairs, kerbs and the lip of a ramp
 right for free.

 **Going downhill needs a snap, and without it a character flies.** Walking off
 the top of a slope, the horizontal move leaves the ground and gravity has not
 yet pulled it back, so the character leaves the surface for a frame, then falls,
 then lands — sixty times a second, which reads as juddering rather than as
 flying. So a character that *was* grounded and whose move left it just above the
 ground is pulled back down to it. `snap` is how far that may be, and past it the
 ledge is a ledge and it falls.
*>
module three;

import std::collections::list;
import std::math;
import std::math::vector;
import std::math::matrix;
import collision;

<*
 The shape and the rules a move is made under.

 The capsule is upright and measured the way `Scene.sweep_capsule` measures one:
 `half_height` is the centre to a hemisphere's centre, so the whole thing is
 `2 * (half_height + radius)` tall. A 1.8 m person with a 0.3 m radius is
 `radius: 0.3, half_height: 0.6`.
*>
struct MoveOptions
{
	float radius;
	float half_height;

	<*
	 How high a ledge may be and still be walked up rather than into.

	 Zero disables the climb entirely, which is what a flying or swimming body
	 wants. The cost of a non-zero value is two extra sweeps on any frame that
	 hits something, and only on those frames.
	*>
	float step_height;

	<*
	 The steepest ground that still counts as ground, in degrees from level.

	 It decides three things at once and they have to agree: whether `grounded`
	 is reported, whether a step-up is accepted, and whether a contact is treated
	 as a floor to stand on or a wall to slide along. Splitting them into three
	 numbers is how a character ends up standing on a slope it cannot climb.
	*>
	float slope_limit;

	<*
	 How far the capsule is kept off every surface, in world units.

	 Small and load-bearing. A capsule resting exactly on a face is at distance
	 zero from it, and every test that asks "how much clearance is there" then
	 answers zero — so the next sweep reports a hit before it has moved, the
	 slide projects a zero-length motion, and the character is stuck against a
	 floor it is standing on. A millimetre or two of gap is what keeps the
	 arithmetic away from that edge.
	*>
	float skin;

	<*
	 How far below the feet the ground may be and still be snapped to. See the
	 header for what happens without it.
	*>
	float snap;

	// How many times the motion may be projected and re-swept. Four is enough
	// for a corner (two walls) with two to spare; past that the residual motion
	// is dropped, which stops a character in a wedge rather than letting it
	// jitter between two faces for ever.
	int max_slides;
}

const int MOVE_DEFAULT_SLIDES = 4;

<*
 Sensible numbers for a person, so a caller who supplied none gets a character
 rather than a division by zero.
*>
fn MoveOptions default_move_options()
{
	return {
		.radius = 0.3f,
		.half_height = 0.6f,
		.step_height = 0.35f,
		.slope_limit = 50.0f,
		.skin = 0.02f,
		.snap = 0.3f,
		.max_slides = MOVE_DEFAULT_SLIDES,
	};
}

<*
 Where the capsule ended up, and everything the move learned on the way.

 **`grounded`, `slope` and `ground` are the answers a game asks for and cannot
 cheaply work out afterwards.** A script can raycast down to find the floor, but
 that ray is a different question from the one the move already answered — it can
 find a floor the capsule's shoulder is not actually over, and it costs a second
 query per frame per character.
*>
struct MoveResult
{
	Vec3 position;

	// What was left of the motion when the slides ran out. Zero on a clean
	// move, and worth reading only to notice a character wedged in a corner.
	Vec3 remaining;

	bool grounded;
	// Degrees from level of whatever is being stood on. Zero when airborne, and
	// zero is also flat ground — `grounded` is what tells the two apart.
	float slope;
	NodeId ground;

	// The last thing the sweep ran into, and its outward normal. NO_NODE and a
	// zero vector on a move that touched nothing.
	NodeId hit;
	Vec3 normal;

	// True when a ledge was climbed on this move. A footstep sound, an
	// animation, or nothing — but it is invisible from the outside otherwise,
	// because a successful climb looks exactly like walking on level ground.
	bool stepped;

	uint slides;
}

<*
 Push the capsule out of anything it is already inside.

 **Run before the sweep, every move, and it is not paranoia.** A character
 arrives overlapping geometry constantly and by ordinary means: it was spawned
 there, the floor moved into it, a slide left it a hair inside a face, or the
 skin was not quite enough at a corner where two planes both push. Conservative
 advancement cannot help — it measures a clearance that is already negative and
 has nowhere to step to — so the sweep would report a hit at fraction zero, the
 slide would have no motion to project, and the character would be pinned. That
 failure is permanent and looks like the controller being broken rather than
 like one bad frame.

 Iterative because the corrections interact: pushing out of a floor can push into
 a wall. Three passes settles a corner; a wedge tight enough to need more is one
 the character should not be in, and stopping is better than looping.

 @return `The corrected centre.`
*>
fn Vec3 Scene.depenetrate_capsule(&self, Assets* assets, Vec3 centre, MoveOptions options, IgnoreSet skip)
{
	if (assets == null) return centre;

	float clearance = options.radius + options.skin;
	Vec3 at = centre;

	for (int pass = 0; pass < 3; pass++)
	{
		Vec3 reach = { clearance, clearance + options.half_height, clearance };
		collision::Aabb3 box = { at - reach, at + reach };

		bool moved = false;
		@pool()
		{
			List{collision::TriangleVerts} triangles;
			triangles.tinit(64);
			List{NodeId} owners;
			owners.tinit(64);
			self.gather_triangles(assets, box, skip, &triangles, &owners);

			Vec3 head = at + (Vec3) { 0, options.half_height, 0 };
			Vec3 tail = at - (Vec3) { 0, options.half_height, 0 };

			foreach (tri : triangles)
			{
				SegmentTriangle pair = segment_triangle_closest(tail, head, tri);
				if (pair.distance >= clearance) continue;

				Vec3 push = pair.on_segment - pair.on_triangle;
				float length = push.length();
				Vec3 normal;
				if (length > 1e-6f)
				{
					normal = push / length;
				}
				else
				{
					// Dead centre on the face. The triangle's own plane is the
					// only direction there is, and either side of it is equally
					// defensible — up is chosen, because the overwhelmingly
					// common way to be exactly on a face is to be standing on
					// one.
					normal = (tri[1] - tri[0]).cross(tri[2] - tri[0]);
					float n = normal.length();
					normal = n > 1e-9f ? normal / n : (Vec3) { 0, 1, 0 };
					if (normal.y < 0.0f) normal = -normal;
				}

				at += normal * (clearance - pair.distance);
				head = at + (Vec3) { 0, options.half_height, 0 };
				tail = at - (Vec3) { 0, options.half_height, 0 };
				moved = true;
			}
		};
		if (!moved) break;
	}

	return at;
}

<*
 Sweep from `at` towards `at + motion`, and stop a hair short of whatever is hit.

 The hair is what keeps the capsule off the surface it stopped against. Without
 it the next move starts at zero clearance — see `MoveOptions.skin`.
*>
fn Vec3 Scene.slide_step(
	&self, Assets* assets, Vec3 at, Vec3 motion, MoveOptions options, IgnoreSet skip, SweepHit* out
)
{
	SweepHit hit = self.sweep_capsule(assets, at, at + motion, options.radius, options.half_height, options.skin, skip);
	*out = hit;
	if (!hit.hit) return at + motion;

	// `distance` is measured along the motion, so backing off along it is what
	// leaves the gap perpendicular to whatever was hit — backing off along the
	// contact normal instead would move the capsule sideways at a glancing
	// contact, which reads as the character being nudged by a wall it brushed.
	float travel = motion.length();
	if (travel < 1e-9f) return at;
	return at + (motion / travel) * math::max(hit.distance, 0.0f);
}

<*
 Whether this normal is a floor rather than a wall, under the slope limit.

 One function so that `grounded`, the step-up test and the slide's choice all
 read the same rule — see `MoveOptions.slope_limit`.
*>
fn bool walkable(Vec3 normal, float slope_limit) @local
{
	// A limit of 90 or more means everything is walkable, which is what a
	// caller asking for a body that sticks to walls means by it.
	if (slope_limit >= 90.0f) return normal.y > 0.0f;
	return normal.y >= math::cos(math::deg_to_rad(math::max(slope_limit, 0.0f)));
}

<*
 Move a capsule through the scene's geometry, sliding along what it hits.

 The one verb — `three.moveAndSlide`. Everything a character controller is, and
 the reason the file's header argues about kinematics.

 @param centre : `Where the capsule's centre is now, in world space.`
 @param motion : `How far it wants to go this frame. Gravity is the caller's: this integrates nothing and remembers nothing between calls.`
 @param skip : `The character's own nodes, subtrees included, so it does not collide with its own mesh. An empty set if it draws nothing. A character is usually a Group — see IgnoreSet.`
*>
fn MoveResult Scene.move_capsule(
	&self, Assets* assets, Vec3 centre, Vec3 motion, MoveOptions options, IgnoreSet skip
)
{
	MoveResult result = {
		.position = centre,
		.remaining = { 0, 0, 0 },
		.ground = NO_NODE,
		.hit = NO_NODE,
		.normal = { 0, 0, 0 },
	};
	if (assets == null)
	{
		result.position = centre + motion;
		return result;
	}

	if (options.max_slides <= 0) options.max_slides = MOVE_DEFAULT_SLIDES;
	float skin = math::max(options.skin, 1e-4f);
	options.skin = skin;

	Vec3 at = self.depenetrate_capsule(assets, centre, options, skip);

	// Was it standing on something before the move? The snap below is only for a
	// character that was already walking — a jump must not be pulled straight
	// back to the floor it just left, and the difference between the two is
	// exactly this reading, taken before anything moved.
	bool was_grounded = false;
	{
		SweepHit probe = self.sweep_capsule(
			assets, at, at - (Vec3) { 0, skin * 4.0f, 0 },
			options.radius, options.half_height, skin, skip);
		was_grounded = probe.hit && walkable(probe.normal, options.slope_limit);
	}

	Vec3 left = motion;
	uint slides = 0;

	for (int i = 0; i < options.max_slides; i++)
	{
		if (left.length_sq() < 1e-12f) break;

		SweepHit hit;
		Vec3 next = self.slide_step(assets, at, left, options, skip, &hit);
		at = next;

		if (!hit.hit)
		{
			left = { 0, 0, 0 };
			break;
		}

		result.hit = hit.node;
		result.normal = hit.normal;
		slides++;

		// What is left of the motion after the part that was used up.
		Vec3 travelled = hit.distance > 0.0f ? left.normalize() * hit.distance : (Vec3) { 0, 0, 0 };
		Vec3 rest = left - travelled;

		// The step-up, and only for a wall: a slope under the limit is walked up
		// by the slide below, and trying to climb it as well would let a
		// character hop up an incline it is already smoothly ascending.
		if (options.step_height > 0.0f && !walkable(hit.normal, options.slope_limit))
		{
			Vec3 flat = { rest.x, 0, rest.z };
			if (flat.length_sq() > 1e-12f)
			{
				Vec3 climbed;
				if (self.try_step_up(assets, at, flat, options, skip, &climbed))
				{
					at = climbed;
					result.stepped = true;
					left = { 0, 0, 0 };
					break;
				}
			}
		}

		// Project onto the contact plane. This is the slide, and it is one line:
		// remove the component of the motion that pushes into the surface and
		// keep the rest.
		left = rest - hit.normal * rest.dot(hit.normal);
	}

	result.remaining = left;
	result.slides = slides;

	// The ground, after the move. A short probe rather than a re-use of the last
	// contact: the last thing hit may have been a wall, and standing is a
	// question about what is under the feet now.
	float probe_depth = skin * 4.0f;
	if (was_grounded && options.snap > 0.0f && motion.y <= 0.0f) probe_depth = math::max(probe_depth, options.snap);

	SweepHit floor = self.sweep_capsule(
		assets, at, at - (Vec3) { 0, probe_depth, 0 },
		options.radius, options.half_height, skin, skip);

	if (floor.hit && walkable(floor.normal, options.slope_limit))
	{
		result.grounded = true;
		result.ground = floor.node;
		result.slope = math::acos(math::clamp(floor.normal.y, -1.0f, 1.0f)) * (float)(180.0 / math::PI);

		// The snap. Only downwards, only when it was already walking, and only
		// as far as `snap` — see the header for the judder it exists to remove.
		if (was_grounded && motion.y <= 0.0f && floor.distance > 0.0f)
		{
			at.y -= floor.distance;
		}
	}

	result.position = at;
	return result;
}

<*
 Try to climb what is in front of the capsule: up, across, and back down.

 Accepted only when the down sweep lands on something walkable *and* lands
 higher than where the capsule started — the second half is what stops a "climb"
 that simply drops the character into the hole it was about to walk into, which
 is what the up-across-down sequence does at the edge of a pit.

 @param flat : `The horizontal motion left over, which is what the climb is trying to spend.`
 @return `Whether the climb was taken, with the new centre in out.`
*>
fn bool Scene.try_step_up(
	&self, Assets* assets, Vec3 at, Vec3 flat, MoveOptions options, IgnoreSet skip, Vec3* out
)
{
	SweepHit ignored;

	// Up. A ceiling low enough to stop the lift is a ledge that cannot be
	// climbed from here, whatever is in front.
	Vec3 lifted = self.slide_step(assets, at, (Vec3) { 0, options.step_height, 0 }, options, skip, &ignored);
	if (lifted.y - at.y < options.step_height * 0.5f) return false;

	// Across. A climb that cannot make meaningful horizontal progress is a wall
	// that is simply taller than the step, and taking it would leave the
	// character standing on top of its own foot.
	Vec3 across = self.slide_step(assets, lifted, flat, options, skip, &ignored);
	Vec3 gained = { across.x - at.x, 0, across.z - at.z };
	if (gained.length_sq() < flat.length_sq() * 0.04f) return false;

	// Down, by the whole lift plus the gap it was raised by. Anything less
	// leaves the capsule hovering a step above the ledge it just climbed.
	SweepHit landing;
	Vec3 drop = { 0, -(options.step_height + options.skin * 2.0f), 0 };
	Vec3 landed = self.slide_step(assets, across, drop, options, skip, &landing);

	if (!landing.hit) return false;
	if (!walkable(landing.normal, options.slope_limit)) return false;
	if (landed.y < at.y - options.skin) return false;

	*out = landed;
	return true;
}
