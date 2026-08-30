<*
 Steering: seek, arrive and separation for a whole crowd in one call.

 One verb over an array rather than five verbs over an agent, because a host
 call is cheap but an *allocating* host call is not — a verb returning a boolean
 costs ~55 ns against JavaScript's 70, and the same crossing returning nine
 numbers costs 185. So a verb answering with vectors writes into a
 `Float32Array` the caller owns. One crossing per frame writes the desired
 velocity of every agent, into memory the script allocated once.

 That also settles where seek and arrive live. Alone they are four multiplies
 and belong in JavaScript, but they compose with separation and with the flow
 field, which do not — splitting the composition across the boundary would mean
 three crossings and two intermediate arrays per frame to save arithmetic that
 was never the cost.

 Separation is the part that needs a host at all. Seek and arrive are per-agent;
 separation is every agent against every other, so two hundred agents is forty
 thousand distance tests per frame, which in QuickJS is milliseconds. The grid
 below makes that linear in the crowd and constant in its density. It is rebuilt
 per call because the agents have all moved since the last one, and a rebuild
 over a flat array is cheaper than the updates would be.
*>
module three;

import std::collections::list;
import std::math;
import std::math::vector;
import collision;

<*
 What the crowd is being asked to do.

 `goal` and the flow field are alternatives, and the field wins when present: a
 field already knows the way around a wall and a goal does not, so a caller with
 both meant the field and was naming the goal for the arrive.
*>
struct SteerOptions
{
	// Where everybody is heading when there is no field. Ignored when one is
	// given, except by the arrive below.
	Vec3 goal;
	bool has_goal;

	float max_speed;

	<*
	 How close to the goal an agent starts slowing down, in world units.

	 Zero means "do not" — full speed until the goal is reached, which is what a
	 projectile wants and what makes a crowd of people orbit a door for ever.
	 The taper is linear rather than exponential because an exponential one
	 never actually arrives, and an agent that never arrives goes on pushing its
	 neighbours out of the way.
	*>
	float arrive_radius;

	// How close two agents may get before they push apart, and how hard. A
	// weight of 1 makes separation exactly as strong as the pull towards the
	// goal at the moment of full overlap.
	float separation_radius;
	float separation_weight;
}

// The most neighbours one agent is pushed by. A crowd dense enough to have more
// than this within a body's width is a crush, and the ones past the cap push in
// the same direction as the ones counted — the sum is already saturated.
const int STEER_MAX_NEIGHBOURS = 24;

<*
 A bucket grid over the agents, thrown away at the end of the call.

 A counting sort, like `scene/query.c3`'s index and for the same reason: it is
 rebuilt every frame, so nothing may allocate per cell.
*>
struct AgentGrid @local
{
	List{int} starts;
	List{int} items;
	float cell;
	int[<3>] origin;
	int[<3>] dims;
	bool usable;
}

fn void AgentGrid.build(&self, float[] positions, int count, float cell)
{
	self.usable = false;
	if (count <= 0 || cell <= 0.0f) return;

	collision::Aabb3 box = collision::NEW_AABB3;
	for (int i = 0; i < count; i++)
	{
		box.expand_by_point((Vec3) { positions[i * 3], positions[i * 3 + 1], positions[i * 3 + 2] });
	}

	self.cell = cell;
	self.origin = {
		(int)math::floor(box.min.x / cell),
		(int)math::floor(box.min.y / cell),
		(int)math::floor(box.min.z / cell),
	};
	int[<3>] top = {
		(int)math::floor(box.max.x / cell),
		(int)math::floor(box.max.y / cell),
		(int)math::floor(box.max.z / cell),
	};
	self.dims = { top.x - self.origin.x + 1, top.y - self.origin.y + 1, top.z - self.origin.z + 1 };

	long cells = (long)self.dims.x * (long)self.dims.y * (long)self.dims.z;
	// A crowd spread over a level with a body-width cell asks for a grid far
	// larger than the crowd. Past four cells per agent the grid is mostly empty
	// and the quadratic loop it replaces was never the cost, so the caller is
	// quietly given that loop back — see `separation_of`.
	if (cells <= 0 || cells > (long)count * 4 + 64) return;

	self.starts.tinit((sz)cells + 1);
	for (long i = 0; i <= cells; i++) self.starts.push(0);
	self.items.tinit((sz)count);
	for (int i = 0; i < count; i++) self.items.push(0);

	for (int i = 0; i < count; i++)
	{
		self.starts[(sz)self.key_of(positions, i) + 1]++;
	}
	for (sz i = 1; i < self.starts.len(); i++) self.starts[i] += self.starts[i - 1];

	List{int} cursor;
	cursor.tinit((sz)cells);
	for (long i = 0; i < cells; i++) cursor.push(self.starts[(sz)i]);
	for (int i = 0; i < count; i++)
	{
		sz k = (sz)self.key_of(positions, i);
		self.items[(sz)cursor[k]] = i;
		cursor[k]++;
	}

	self.usable = true;
}

fn int AgentGrid.key_of(&self, float[] positions, int agent)
{
	int x = math::clamp((int)math::floor(positions[agent * 3] / self.cell) - self.origin.x, 0, self.dims.x - 1);
	int y = math::clamp((int)math::floor(positions[agent * 3 + 1] / self.cell) - self.origin.y, 0, self.dims.y - 1);
	int z = math::clamp((int)math::floor(positions[agent * 3 + 2] / self.cell) - self.origin.z, 0, self.dims.z - 1);
	return (z * self.dims.y + y) * self.dims.x + x;
}

<*
 The push one agent gets from the others near it.

 Weighted by overlap depth rather than inverse distance: an inverse blows up as
 two agents coincide, which they do the moment two share a spawn point, and one
 frame of an infinite push throws an agent across the level. A linear taper from
 touching to fully overlapping is bounded by construction.
*>
fn Vec3 separation_of(AgentGrid* grid, float[] positions, int count, int agent, float radius) @local
{
	Vec3 here   = { positions[agent * 3], positions[agent * 3 + 1], positions[agent * 3 + 2] };
	Vec3 push   = { 0, 0, 0 };
	int counted = 0;
	float r_sq  = radius * radius;

	if (!grid.usable)
	{
		// The quadratic fallback — see `AgentGrid.build`. Correct and slower,
		// reached only for a crowd so spread out that almost every pair is
		// rejected on the first compare anyway.
		for (int other = 0; other < count && counted < STEER_MAX_NEIGHBOURS; other++)
		{
			if (other == agent) continue;
			Vec3 away  = here - (Vec3) { positions[other * 3], positions[other * 3 + 1], positions[other * 3 + 2] };
			float d_sq = away.length_sq();
			if (d_sq >= r_sq) continue;
			push += taper(away, d_sq, radius);
			counted++;
		}
		return push;
	}

	int reach = (int)math::ceil(radius / grid.cell);
	int[<3>] centre = {
		math::clamp((int)math::floor(here.x / grid.cell) - grid.origin.x, 0, grid.dims.x - 1),
		math::clamp((int)math::floor(here.y / grid.cell) - grid.origin.y, 0, grid.dims.y - 1),
		math::clamp((int)math::floor(here.z / grid.cell) - grid.origin.z, 0, grid.dims.z - 1),
	};

	for (int dz = -reach; dz <= reach && counted < STEER_MAX_NEIGHBOURS; dz++)
	{
		int z = centre.z + dz;
		if (z < 0 || z >= grid.dims.z) continue;
		for (int dy = -reach; dy <= reach && counted < STEER_MAX_NEIGHBOURS; dy++)
		{
			int y = centre.y + dy;
			if (y < 0 || y >= grid.dims.y) continue;
			for (int dx = -reach; dx <= reach && counted < STEER_MAX_NEIGHBOURS; dx++)
			{
				int x = centre.x + dx;
				if (x < 0 || x >= grid.dims.x) continue;

				sz k = (sz)((z * grid.dims.y + y) * grid.dims.x + x);
				for (sz at = (sz)grid.starts[k]; at < (sz)grid.starts[k + 1]; at++)
				{
					int other = grid.items[at];
					if (other == agent) continue;
					Vec3 away  = here - (Vec3) {
						positions[other * 3],
						positions[other * 3 + 1],
						positions[other * 3 + 2]
					};
					float d_sq = away.length_sq();
					if (d_sq >= r_sq) continue;
					push += taper(away, d_sq, radius);
					counted++;
					if (counted >= STEER_MAX_NEIGHBOURS) break;
				}
			}
		}
	}

	return push;
}

fn Vec3 taper(Vec3 away, float distance_sq, float radius) @local
{
	float distance = math::sqrt(distance_sq);
	if (distance < 1e-5f)
	{
		// Exactly on top of one another, as two agents spawned at one point
		// are. Any direction resolves it and none is more correct, so the
		// agent's index decides — a fixed direction would leave the pair pushing
		// the same way for ever and never separating.
		return { 0, 0, 0 };
	}
	return (away / distance) * ((radius - distance) / radius);
}

<*
 Fills `out` with a desired velocity per agent.

 @param positions : `Three floats per agent, x/y/z. Read only.`
 @param out : `Three floats per agent. Written, never read.`
 @param nav : `The baked mesh the field belongs to, or null for goal-seeking only.`
 @param field : `A solved flow field over that mesh, or empty.`
*>
fn void steer_agents(float[] positions, float[] out, NavMesh* nav, float[] field, SteerOptions options)
{
	int count = (int)math::min(positions.len / 3, out.len / 3);
	if (count <= 0) return;

	float speed    = options.max_speed > 0.0f ? options.max_speed : 1.0f;
	bool use_field = nav != null && nav.usable() && field.len == nav.grid.cells.len;

	AgentGrid grid;
	if (options.separation_radius > 0.0f && options.separation_weight != 0.0f)
	{
		grid.build(positions, count, options.separation_radius);
	}

	for (int i = 0; i < count; i++)
	{
		Vec3 here = { positions[i * 3], positions[i * 3 + 1], positions[i * 3 + 2] };

		Vec3 want       = { 0, 0, 0 };
		float remaining = float::max;

		if (use_field)
		{
			want = nav.direction_at(field, here);
			float cost = nav.cost_at(field, here);
			if (cost < collision::VOXEL_UNREACHED) remaining = cost;
		}
		else if (options.has_goal)
		{
			Vec3 towards = options.goal - here;
			// Flattened, like the field's answer: an agent walks, and the y of
			// a step is the ground's business. A caller steering something that
			// flies wants its own arithmetic, not this verb.
			towards.y = 0.0f;
			remaining = towards.length();
			if (remaining > 1e-6f) want = towards / remaining;
		}

		// Arrive: taper the speed inside the radius, stopping dead at the goal
		// rather than asymptotically near it — see `SteerOptions.arrive_radius`.
		float wanted_speed = speed;
		if (options.arrive_radius > 0.0f && remaining < options.arrive_radius)
		{
			wanted_speed = speed * (remaining / options.arrive_radius);
		}

		Vec3 velocity = want * wanted_speed;

		if (grid.usable || (options.separation_radius > 0.0f && options.separation_weight != 0.0f))
		{
			Vec3 apart = separation_of(&grid, positions, count, i, options.separation_radius);
			apart.y = 0.0f;
			velocity += apart * (options.separation_weight * speed);
		}

		// One clamp at the end rather than one per term: clamping the seek and
		// then adding separation is how a crowd ends up moving faster in a scrum
		// than in the open.
		float length = velocity.length();
		if (length > speed && length > 1e-9f) velocity = velocity * (speed / length);

		out[i * 3] = velocity.x;
		out[i * 3 + 1] = velocity.y;
		out[i * 3 + 2] = velocity.z;
	}
}