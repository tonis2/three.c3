<*
 Navigation — `notes.md` §17.

 ## What was already here, and the one thing that was not

 Both halves of this had their inputs in the repo. Every uploaded mesh keeps
 `hull_positions`, `hull_triangles` and a `TriBVHNode` (`scene/asset.c3`), and
 `lib/collision.c3l/src/voxel.c3` is a written, tested distance-field solver
 — `solve_field`, `sample`, `nearest_solved`, and a multi-source
 `solve_sources` / `nearest_sourced` / `sample_sources` that is a crowd flow
 field by another name. Nothing in `src/` imported any of it.

 The piece genuinely missing was the **complement**. `create_voxel_grid`
 voxelizes the *inside* of a closed mesh: it marches lines through the model and
 uses the parity of the crossings to decide what is material. Navigation wants
 the opposite of that in two ways at once — the *outside* of many *open* meshes,
 and not all of the outside but the thin layer of it that is standing room. A
 town is not a closed mesh and its interior is not where anybody walks.

 So this builds the grid rather than borrowing one. `VoxelGrid` is a plain
 struct — an origin, a cell size, three extents, a voxel-to-entry index and an
 ascending entry-to-voxel list — and every field routine on it works on any
 sparse cell set that obeys those two arrays. Filling them with standing room
 instead of with material is the whole of what this file adds; the solver,
 the sampling, the interpolation and the multi-source crowd machinery are used
 exactly as they were written.

 ## Two verbs, and the split is the design

 `nav.path(from, to)` for one agent, `nav.field(goals)` for a handle a script
 samples per agent. §17 was explicit that offering only `path()`
 guarantees somebody writes the second one badly — and the reason is a cost, not
 a taste: a path is a solve of the whole reachable set, thrown away after one
 answer. A hundred agents heading for the same door is a hundred solves for one
 field. `field()` is that solve, kept.

 ## What a cell is, and what that costs a caller

 A cell is walkable when it is empty, the cell below it holds a triangle whose
 normal is inside the slope limit, and the cells above it are empty for the
 agent's height. So there is exactly **one walkable layer per floor**, which is
 what makes a bridge over a road two layers rather than an ambiguity.

 The consequence a caller has to know is that **a step is one cell**. The
 solver relaxes over a 3x3x3 neighbourhood, so two walkable cells are connected
 when they are adjacent — including diagonally and including one cell up. A
 stair with a rise larger than the cell size is not a stair to this grid, it is
 a wall. At the default half-metre cell that is a generous step; a scene with
 finer stairs wants a finer cell, and pays for it as the cube.
*>
module three;

import std::collections::list;
import std::math;
import std::math::vector;
import std::math::matrix;
import collision;
import std::time;

<*
 What a bake was asked for.

 Every one of these is a property of the *agent*, not of the level, which is why
 a scene can hold more than one baked mesh: a crowd of people and a herd of
 vehicles walk different graphs over the same triangles.
*>
struct NavSettings
{
	// The voxel size, in world units. The single number that decides both the
	// bake's cost and everything it can represent — see the header on steps.
	float cell;

	// How wide the agent is. Free space is eroded by this before anything is
	// called walkable, so a corridor narrower than the agent has no cells in it
	// rather than a centre line the agent cannot fit on. The erosion grows out
	// of walls and not out of floors — `bake_nav` has the argument, and it is
	// what keeps a ramp connected to itself.
	float agent_radius;

	// How tall it is. Cells above a floor must be clear for this height or the
	// floor is not standing room.
	float agent_height;

	// The steepest floor it will stand on, in degrees. Measured from the
	// triangle normals under a cell, not from the shape of the voxels, so a
	// ramp is a ramp and not a staircase of cells.
	float slope_limit;

	// The region to bake. An empty box means the scene's own bounds, which is
	// what a caller who has not thought about it means and is right until a
	// level is big enough for the bake to be a loading screen.
	collision::Aabb3 bounds;
	bool has_bounds;
}

fn NavSettings default_nav_settings()
{
	return {
		.cell = 0.5f,
		.agent_radius = 0.35f,
		.agent_height = 1.8f,
		.slope_limit = 50.0f,
		.has_bounds = false,
	};
}

// A hard ceiling on the voxels one bake may allocate, so a script that asks for
// a five-centimetre cell over a kilometre is refused rather than being handed
// the machine's memory. 16 million cells is 64 MB of index and is already far
// past what a level wants.
const long NAV_MAX_VOXELS = 16_000_000;

// Padding cells on every side. `collision::relax_voxel` steps its whole 3x3x3
// neighbourhood with no bounds test, on the promise that every entry is at
// least two cells from the edge — this is that promise, and it is why nothing
// in the padding may ever be marked walkable.
const int NAV_PAD = 2;

<*
 A baked navigation grid, and what it cost to bake.

 The counters are reported through `three.nav.stats` because §17 asked
 for the bake cost to be measured before the shape of the API is settled: "that
 number decides whether this is a level-boundary operation or a loading-screen
 one". A caller can now answer it for their own level rather than for a
 reference one.
*>
struct NavMesh
{
	collision::VoxelGrid grid;
	NavSettings settings;
	bool built;

	uint solid_cells;
	uint floor_cells;
	uint walkable_cells;
	long voxels;
	double bake_ms;

	<*
	 How many disjoint regions the walkable set came out in, and how big the
	 biggest one is.

	 **The number that says whether the bake is usable**, and the one thing
	 that was missing when the erosion bug below cut a trail into islands: a
	 bake returns a healthy `walkable_cells`, `field` returns a live field
	 rather than null, and every other counter here looks exactly right, so the
	 only thing that showed it was asking a *second* point whether it was
	 reachable. `components == 1` is a level an agent can cross; anything else
	 is a level where "there is no path" is the honest answer for some pairs of
	 points, and a caller who did not intend that wants to know at bake time.

	 Measured over the same 26-neighbour adjacency `collision::relax_voxel`
	 relaxes across, so it is exactly the graph a field is solved on rather
	 than an approximation of it.
	*>
	uint components;
	uint largest_component;
}

fn void NavMesh.free(&self)
{
	self.grid.free();
	*self = {};
}

fn bool NavMesh.usable(&self) => self.built && self.grid.usable();

<*
 Voxelize the scene's standing room.

 One pass over the triangles to mark what is solid and what of it is floor, one
 dilation to make room for the agent's width, and one pass to pick out the cells
 that are standing room. Nothing is iterative and nothing is approximate beyond
 the cell size.

 @return `False when the region held no walkable cell at all — an empty scene, a scene with no floor under the slope limit, or a cell size larger than the level.`
*>
fn bool Scene.bake_nav(&self, Assets* assets, NavSettings settings, NavMesh* out)
{
	out.free();
	out.settings = settings;

	if (assets == null) return false;
	float cell = settings.cell > 0.0f ? settings.cell : 0.5f;

	collision::Aabb3 region = settings.bounds;
	if (!settings.has_bounds) region = self.bounds(assets);
	if (region.size().length_sq() <= 0.0f) return false;

	// Room above the tallest thing for the headroom test to look into, and a
	// cell below the lowest for a floor to sit on.
	region.min -= (Vec3) { cell, cell, cell };
	region.max += (Vec3) { cell, settings.agent_height + cell, cell };

	Vec3 span = region.size();
	int nx = (int)math::ceil(span.x / cell) + 2 * NAV_PAD + 1;
	int ny = (int)math::ceil(span.y / cell) + 2 * NAV_PAD + 1;
	int nz = (int)math::ceil(span.z / cell) + 2 * NAV_PAD + 1;
	long total = (long)nx * (long)ny * (long)nz;
	if (total <= 0 || total > NAV_MAX_VOXELS) return false;

	out.voxels = total;

	Vec3 origin = region.min - (Vec3) { cell * (float)NAV_PAD, cell * (float)NAV_PAD, cell * (float)NAV_PAD };

	// `solid` is what a triangle is in; `floor` is the subset of it whose
	// triangles are shallow enough to stand on. They are separate because the
	// dilation below applies to one and not the other: a wall next to a floor
	// must not stop the floor beside it being a floor, it must only stop the
	// agent's *centre* getting within a radius of the wall.
	char[] solid = mem::new_array(char, (sz)total);
	char[] floor = mem::new_array(char, (sz)total);
	defer mem::free(solid);
	defer mem::free(floor);

	Clock started = clock::now();

	float cos_limit = math::cos(math::deg_to_rad(math::clamp(settings.slope_limit, 0.0f, 89.9f)));

	@pool()
	{
		List{collision::TriangleVerts} triangles;
		triangles.tinit(256);
		List{NodeId} owners;
		owners.tinit(256);
		self.gather_triangles(assets, region, {}, &triangles, &owners);

		foreach (tri : triangles)
		{
			Vec3 normal = (tri[1] - tri[0]).cross(tri[2] - tri[0]);
			float area = normal.length();
			// A degenerate triangle has no normal and no area; it is still
			// solid, so it is rasterized and simply never counts as floor.
			bool standable = area > 1e-9f && math::abs(normal.y / area) >= cos_limit;

			collision::Aabb3 box = collision::NEW_AABB3;
			box.expand_by_point(tri[0]);
			box.expand_by_point(tri[1]);
			box.expand_by_point(tri[2]);

			int lo_x = math::clamp((int)math::floor((box.min.x - origin.x) / cell + 0.5f) - 1, 0, nx - 1);
			int hi_x = math::clamp((int)math::floor((box.max.x - origin.x) / cell + 0.5f) + 1, 0, nx - 1);
			int lo_y = math::clamp((int)math::floor((box.min.y - origin.y) / cell + 0.5f) - 1, 0, ny - 1);
			int hi_y = math::clamp((int)math::floor((box.max.y - origin.y) / cell + 0.5f) + 1, 0, ny - 1);
			int lo_z = math::clamp((int)math::floor((box.min.z - origin.z) / cell + 0.5f) - 1, 0, nz - 1);
			int hi_z = math::clamp((int)math::floor((box.max.z - origin.z) / cell + 0.5f) + 1, 0, nz - 1);

			Vec3 half = { cell * 0.5f, cell * 0.5f, cell * 0.5f };
			for (int z = lo_z; z <= hi_z; z++)
			{
				for (int y = lo_y; y <= hi_y; y++)
				{
					for (int x = lo_x; x <= hi_x; x++)
					{
						Vec3 centre = {
							origin.x + (float)x * cell,
							origin.y + (float)y * cell,
							origin.z + (float)z * cell,
						};
						collision::Aabb3 cell_box = { centre - half, centre + half };
						// The exact separating-axis test the BVH already uses,
						// not a bounding-box overlap: a diagonal wall through a
						// room otherwise fills every cell of the box around it
						// and closes the room.
						if (tri.collides_aabb(cell_box) < 0) continue;

						sz at = (sz)((z * ny + y) * nx + x);
						solid[at] = 1;
						if (standable) floor[at] = 1;
					}
				}
			}
		}
	};

	uint solid_count = 0;
	uint floor_count = 0;
	foreach (v : solid) if (v != 0) solid_count++;
	foreach (v : floor) if (v != 0) floor_count++;
	out.solid_cells = solid_count;
	out.floor_cells = floor_count;

	// Erode the free space by the agent's width, by dilating the **walls**
	// horizontally — the solid cells that are not floor. Horizontally only:
	// growing it vertically would swallow the standing room above every floor,
	// which is the space being looked for.
	//
	// **Walls rather than the whole solid set, and that is a bug fix rather
	// than a refinement** (`plan.md` §17). Dilating every solid cell is correct
	// only while the floor is level. The moment it is not, the uphill column's
	// *floor* cell sits at the walkable layer of the column beside it — that is
	// what a slope is — so growing it sideways blocks exactly the cell the
	// downhill agent had to stand in, and any descending floor comes out of the
	// bake as islands one dilation apart. Measured on a 5.7-degree ramp at
	// `cell: 0.6`: `agent_radius: 0.43` reached 1 of 49 points down a 200-unit
	// trail where `0.30` — the same bake with `grow` rounding to zero — reached
	// all 49. A flat corridor was whole either way, which is why it survived
	// every test until a level had a hill in it.
	//
	// A wall keeps its clearance, because a wall is not floor. A ramp keeps its
	// continuity, because ground you stand *on* is not something to keep clear
	// *of*. The seam where a floor triangle and a wall triangle share a cell is
	// left out of the dilation, and the wall's own cells above it are not, so
	// the clearance is still there one layer up where the agent's chest is.
	int grow = (int)math::ceil(math::max(settings.agent_radius, 0.0f) / cell - 0.5f);
	char[] blocked = solid;
	char[] dilated;
	if (grow > 0)
	{
		dilated = mem::new_array(char, (sz)total);
		// Seeded with the whole solid set, so `blocked` keeps meaning "a cell
		// the agent's centre may not be in" — a cell inside geometry is blocked
		// whether or not anything was grown into it. Only the *source* of the
		// dilation is narrowed.
		mem::copy(dilated.ptr, solid.ptr, (usz)total);
		for (int z = 0; z < nz; z++)
		{
			for (int y = 0; y < ny; y++)
			{
				for (int x = 0; x < nx; x++)
				{
					sz from = (sz)((z * ny + y) * nx + x);
					if (solid[from] == 0 || floor[from] != 0) continue;
					int x0 = math::max(x - grow, 0);
					int x1 = math::min(x + grow, nx - 1);
					int z0 = math::max(z - grow, 0);
					int z1 = math::min(z + grow, nz - 1);
					for (int cz = z0; cz <= z1; cz++)
					{
						for (int cx = x0; cx <= x1; cx++) dilated[(sz)((cz * ny + y) * nx + cx)] = 1;
					}
				}
			}
		}
		blocked = dilated;
	}
	defer if (grow > 0) mem::free(dilated);

	int head = (int)math::ceil(math::max(settings.agent_height, 0.0f) / cell);
	if (head < 1) head = 1;

	// The walkable pass. The padding is excluded from the loop rather than
	// tested inside it — see NAV_PAD for why nothing there may ever be an entry.
	int[] index = mem::new_array(int, (sz)total);
	foreach (&slot : index) *slot = -1;

	List{int} cells;
	cells.init(mem, 1024);

	for (int z = NAV_PAD; z < nz - NAV_PAD; z++)
	{
		for (int y = NAV_PAD; y < ny - NAV_PAD; y++)
		{
			for (int x = NAV_PAD; x < nx - NAV_PAD; x++)
			{
				sz at = (sz)((z * ny + y) * nx + x);
				if (blocked[at] != 0) continue;
				if (floor[(sz)(((z * ny) + (y - 1)) * nx + x)] == 0) continue;

				bool clear = true;
				for (int up = 1; up <= head && clear; up++)
				{
					if (y + up >= ny - NAV_PAD) { clear = false; break; }
					if (blocked[(sz)(((z * ny) + (y + up)) * nx + x)] != 0) clear = false;
				}
				if (!clear) continue;

				index[at] = (int)cells.len();
				cells.push((int)at);
			}
		}
	}

	// Nanoseconds to milliseconds here rather than through `to_ms`, which
	// truncates to whole milliseconds — a bake this reports as "0 ms" is one a
	// caller cannot tell from one that did not run.
	out.bake_ms = (double)(long)started.to_now() / 1_000_000.0;

	if (cells.len() == 0)
	{
		cells.free();
		mem::free(index);
		return false;
	}

	// The grid takes ownership of both arrays; `VoxelGrid.free` releases them.
	out.grid = {
		.origin = origin,
		.cell = cell,
		.nx = nx, .ny = ny, .nz = nz,
		.index = index,
		.cells = cells.to_array(mem),
	};
	cells.free();

	out.walkable_cells = (uint)out.grid.cells.len;
	out.built = true;
	out.settings.cell = cell;

	out.measure_components();
	// Re-stamped, so the number a caller reads is the whole bake and not the
	// part of it that existed before the component pass did.
	out.bake_ms = (double)(long)started.to_now() / 1_000_000.0;
	return true;
}

<*
 Label the walkable set's connected regions, and remember how many there were.

 **`plan.md` §17: nothing reported a fragmented bake.** Every other counter on
 a `NavMesh` is a total, and a total cannot tell a level an agent can cross from
 the same level cut into a hundred islands — which is what the radius erosion
 above used to make of any slope. This is the counter that can, and it is worth
 having on its own: a doorway one cell too narrow, a step one cell too high and
 a ramp that does not quite reach all look identical in `walkable_cells`.

 A flood fill over the same 26-neighbourhood `collision::relax_voxel` steps, so
 "one component" means exactly "`solve_field` can carry a cost from any cell to
 any other". One pass over the cells with an explicit stack — no recursion,
 because a broad sheet of standing room is tens of thousands of cells deep.

 Cheap next to the voxelization it follows: the walk touches each cell once and
 looks at 26 neighbours, against a rasterization that is per triangle per cell.
*>
fn void NavMesh.measure_components(&self)
{
	self.components = 0;
	self.largest_component = 0;
	if (!self.usable()) return;

	sz count = self.grid.cells.len;
	int[] label = mem::new_array(int, count);
	defer mem::free(label);
	foreach (&slot : label) *slot = -1;

	int plane = self.grid.nx * self.grid.ny;

	List{int} stack;
	stack.init(mem, 64);
	defer stack.free();

	for (sz start = 0; start < count; start++)
	{
		if (label[start] >= 0) continue;

		int id = (int)self.components;
		self.components++;
		uint size = 0;

		label[start] = id;
		stack.push((int)start);
		while (stack.len() > 0)
		{
			int entry = stack.pop()!!;
			size++;
			int voxel = self.grid.cells[(sz)entry];

			for (int dz = -1; dz <= 1; dz++)
			{
				for (int dy = -1; dy <= 1; dy++)
				{
					for (int dx = -1; dx <= 1; dx++)
					{
						if (dx == 0 && dy == 0 && dz == 0) continue;
						// Unbounded on purpose, on NAV_PAD's promise that no
						// entry is within two cells of the edge — the same
						// promise `collision::relax_voxel` steps on.
						int neighbour = self.grid.index[voxel + dz * plane + dy * self.grid.nx + dx];
						if (neighbour < 0 || label[(sz)neighbour] >= 0) continue;
						label[(sz)neighbour] = id;
						stack.push(neighbour);
					}
				}
			}
		}

		if (size > self.largest_component) self.largest_component = size;
	}
}

<*
 The distance to the nearest goal, for every walkable cell.

 `collision::VoxelGrid.solve_field` unchanged — a chamfer transform, forward and
 backward sweeps until nothing moves, rather than a priority queue. It is fast
 for exactly the shape a nav layer is (one broad sheet) and it is what already
 existed.

 **This is the expensive call and there is one of it per goal set, not per
 agent.** See the file header.

 @param field : `Scratch the caller owns, one float per walkable cell. NavMesh.field_size is how many.`
 @return `False when no goal landed on a walkable cell, which leaves the field unusable rather than uniformly unreachable.`
*>
fn bool NavMesh.solve(&self, Vec3[] goals, float[] field)
{
	if (!self.usable() || field.len != self.grid.cells.len) return false;

	self.grid.clear_field(field);

	usz seeded = 0;
	foreach (goal : goals) seeded += self.grid.seed_segment(field, goal, goal);
	if (seeded == 0) return false;

	self.grid.solve_field(field);
	return true;
}

fn sz NavMesh.field_size(&self) => self.usable() ? self.grid.cells.len : 0;

<*
 How far from the goal a point is, along the ground rather than through walls.

 `VOXEL_UNREACHED` for a point off the mesh or in a region no goal reaches,
 which is the answer a caller needs in order to give up rather than a large
 number they might mistake for "far".
*>
fn float NavMesh.cost_at(&self, float[] field, Vec3 point)
{
	if (!self.usable() || field.len != self.grid.cells.len) return collision::VOXEL_UNREACHED;
	int fallback = self.grid.nearest_cell(point, NAV_PAD);
	return self.grid.sample(field, point, fallback);
}

<*
 Which way to walk, from a point, to get closer to the goal.

 **The flow field, and the verb an agent actually calls.** A unit vector in the
 XZ plane — flattened deliberately, because an agent walks and the y of a step
 is the ground's business, not the field's. A zero vector means "nowhere to go":
 standing on the goal, off the mesh, or in a pocket the goal cannot reach, and a
 caller has to tell those apart with `cost_at` if it matters.

 The direction is taken from the *cell* neighbourhood rather than from a
 numerical gradient of the interpolated field. A gradient of a chamfer distance
 is noisy at exactly the places it matters — beside a wall, at a doorway — and
 the neighbour with the lowest cost is both cheaper and the answer the graph
 actually encodes.
*>
fn Vec3 NavMesh.direction_at(&self, float[] field, Vec3 point)
{
	if (!self.usable() || field.len != self.grid.cells.len) return { 0, 0, 0 };

	int entry = self.grid.nearest_cell(point, NAV_PAD);
	if (entry < 0) return { 0, 0, 0 };

	int voxel = self.grid.cells[entry];
	float here = field[entry];
	if (here >= collision::VOXEL_UNREACHED) return { 0, 0, 0 };

	int plane = self.grid.nx * self.grid.ny;
	float best = here;
	int best_voxel = -1;

	for (int dz = -1; dz <= 1; dz++)
	{
		for (int dy = -1; dy <= 1; dy++)
		{
			for (int dx = -1; dx <= 1; dx++)
			{
				if (dx == 0 && dy == 0 && dz == 0) continue;
				int step = dz * plane + dy * self.grid.nx + dx;
				int neighbour = self.grid.index[voxel + step];
				if (neighbour < 0) continue;
				float there = field[neighbour];
				if (there >= collision::VOXEL_UNREACHED) continue;
				if (there < best)
				{
					best = there;
					best_voxel = voxel + step;
				}
			}
		}
	}

	if (best_voxel < 0) return { 0, 0, 0 };

	Vec3 towards = self.grid.center(best_voxel) - self.grid.center(voxel);
	towards.y = 0.0f;
	float length = towards.length();
	if (length < 1e-6f) return { 0, 0, 0 };
	return towards / length;
}

<*
 The top of the floor under a walkable cell, which is what a waypoint should be.

 A cell centre is half a cell above the surface, so a path of raw centres floats
 — visibly, on a coarse grid, and it is also the wrong height to sweep a capsule
 from. Subtracting the half cell puts the point on the floor.
*>
fn Vec3 NavMesh.foot_of(&self, int voxel)
{
	Vec3 centre = self.grid.center(voxel);
	centre.y -= self.grid.cell * 0.5f;
	return centre;
}

<*
 Walk the field downhill from `from`, collecting one point per cell.

 The raw path, before shortening. Bounded by the slice it is given and by a step
 count, so a field with a flat spot cannot loop for ever.

 @return `How many points were written. Zero when the start is not on the mesh or the goal is unreachable from it.`
*>
fn uint NavMesh.walk(&self, float[] field, Vec3 from, Vec3[] out)
{
	if (!self.usable() || field.len != self.grid.cells.len || out.len == 0) return 0;

	int entry = self.grid.nearest_cell(from, NAV_PAD);
	if (entry < 0) return 0;

	int voxel = self.grid.cells[entry];
	if (field[entry] >= collision::VOXEL_UNREACHED) return 0;

	uint count = 0;
	out[count++] = self.foot_of(voxel);

	int plane = self.grid.nx * self.grid.ny;
	// One step per cell of the longest possible descent, with slack. A chamfer
	// field is monotonically decreasing along this walk, so the bound is a
	// backstop against a field that was never solved rather than a real limit.
	long limit = (long)self.grid.cells.len + 8;

	for (long step_count = 0; step_count < limit && count < out.len; step_count++)
	{
		int here = self.grid.index[voxel];
		if (here < 0) break;
		float best = field[here];
		if (best <= 0.0f) break;

		int next = -1;
		for (int dz = -1; dz <= 1; dz++)
		{
			for (int dy = -1; dy <= 1; dy++)
			{
				for (int dx = -1; dx <= 1; dx++)
				{
					if (dx == 0 && dy == 0 && dz == 0) continue;
					int candidate = voxel + dz * plane + dy * self.grid.nx + dx;
					int neighbour = self.grid.index[candidate];
					if (neighbour < 0) continue;
					float there = field[neighbour];
					if (there < best) { best = there; next = candidate; }
				}
			}
		}

		if (next < 0) break;
		voxel = next;
		out[count++] = self.foot_of(voxel);
	}

	return count;
}

<*
 Drop a waypoint onto the surface it is over.

 A cell centre is half a cell above the floor and the foot point this subtracts
 that from is only right when the floor happens to line up with the grid — so a
 raw waypoint floats by up to half a cell, visibly on a coarse bake. One ray per
 *kept* waypoint fixes it, and there are a handful of those after shortening
 rather than one per cell.

 Falls back to the point it was given when nothing is under it, which happens
 at the lip of a ledge where the ray goes past the edge: half a cell of float is
 better than a waypoint dropped to the bottom of a pit.
*>
fn Vec3 Scene.on_floor(&self, Assets* assets, Vec3 point, float cell)
{
	collision::Ray down = { .origin = { point.x, point.y + cell, point.z }, .direction = { 0, -1, 0 } };
	Hit hit = self.raycast(assets, down);
	if (!hit.hit || hit.distance > cell * 3.0f) return point;
	return hit.point;
}

<*
 Pull the string tight: drop every waypoint the agent can see past.

 **§17: "a game that walks cell centres looks like it is walking cell
 centres."** A raw voxel path is a staircase of half-metre steps whatever the
 room looks like, and an agent following it weaves. This is the fix, and it is
 the one place the nav layer touches the actual geometry again — the visibility
 test is a capsule sweep through `scene/query.c3`, at the agent's own radius and
 height, so a corner the agent cannot physically round is not cut.

 Greedy and forward-only: from the current anchor, advance while the sweep is
 clear and stop at the first waypoint it is not. That is one sweep per waypoint
 rather than the quadratic all-pairs version, and on a path through a room it
 collapses a hundred cells to two.

 @param path : `The raw walk, as NavMesh.walk wrote it. Foot points, not cell centres.`
 @param out : `Where the shortened path goes. May be the same slice the raw walk is in.`
 @return `How many points were written, always at least one.`
*>
fn uint Scene.shorten_path(
	&self, Assets* assets, NavMesh* nav, Vec3[] path, uint count, Vec3[] out, IgnoreSet skip
)
{
	if (count == 0 || out.len == 0) return 0;
	if (count == 1 || assets == null)
	{
		out[0] = path[0];
		return 1;
	}

	float radius = math::max(nav.settings.agent_radius, 0.05f);
	float half = math::max((nav.settings.agent_height - 2.0f * radius) * 0.5f, 0.0f);
	// The capsule's centre above the foot point the path carries.
	float lift = radius + half;
	// A hair off the floor, so a sweep along a surface the agent is standing on
	// is not a sweep starting in contact with it.
	float skin = nav.grid.cell * 0.05f;

	uint written = 0;
	out[written++] = self.on_floor(assets, path[0], nav.grid.cell);

	uint anchor = 0;
	while (anchor < count - 1 && written < out.len)
	{
		uint reach = anchor + 1;
		// Extend while the next waypoint is visible from the anchor. The first
		// candidate is always accepted without a test: consecutive cells are
		// adjacent by construction, and refusing one would leave the walk stuck.
		while (reach + 1 < count)
		{
			Vec3 a = path[anchor];
			Vec3 b = path[reach + 1];
			a.y += lift;
			b.y += lift;
			SweepHit hit = self.sweep_capsule(assets, a, b, radius, half, skin, skip);
			if (hit.hit) break;
			reach++;
		}
		out[written++] = self.on_floor(assets, path[reach], nav.grid.cell);
		anchor = reach;
	}

	return written;
}
