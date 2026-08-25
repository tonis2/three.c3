<*
 Bulk spatial queries, and the broad phase that makes them worth having —
 `notes.md` §17, which is where the entry's account went once it was built.

 ## What was wrong

 `Scene.raycast` walked **every node in the scene**, transformed its mesh box by
 its world matrix and tested the ray against it, before it reached any BVH:
 42 ns per node, linear in the node count and completely independent of what the
 ray could possibly hit. `notes.md` §17 measured one cast at 21 µs in a 500-node
 scene, and named the consequence — a hundred agents each casting one ground ray
 is 2.1 ms, a quarter of a frame, in a scene small enough to be a demo.

 That is the entry this file pays off, and it pays it twice: the same index
 answers `overlapSphere`, `queryBox`, `raycastAll` and `sweep`, which are the
 verbs a game reaches for and none of which existed.

 ## The index is built on demand, never per frame

 **A frame that asks nothing pays nothing.** The index is rebuilt by the first
 query after anything in the scene moved, and not by the tick — so the cost is
 borne by whoever actually wants it, once, and every query after it in the same
 burst is a cell walk. A hundred ground rays are now one rebuild plus a hundred
 lookups.

 That is also why it is a *rebuild* rather than an incremental
 insert/update/remove against `collision::SpatialHash3D`, which is what the plan
 originally called for and what the solver's broad phase does. Incremental
 maintenance is the right shape for a set of bodies that is mutated one at a time
 and queried every step; it is the wrong shape here, because a world box is only
 knowable after `update_world_matrices`. A rebuild needs no signal at all: it
 reads what is true now.

 The rebuild costs what one old raycast cost — the same per-node box transform,
 over the same nodes — so the break-even is the *second* query in a burst, and
 everything past it is free.

 ## A move is re-filed; a structural change is not

 **What that argument got wrong was the frequency of a move.** The paragraph
 above used to end by saying the scene has no per-node "this one moved" signal
 to hang an update on, so everything was a rebuild — and a gameplay step that
 legitimately moved a character and then swept from its new position paid four
 hundred and thirty re-filings for one moved box, once per sweep. `plan.md` §17
 measured 6.8 ms a step against 0.65 ms for the same eleven characters with
 every write deferred to the animation callback, which made "never write between
 two queries" a rule a script had to know and could not always keep.

 So there is a signal now, and it is narrow on purpose. `Scene.mark_moved`
 hands `Scene.invalidate` the id it already had, `QueryIndex.note_moved`
 remembers it, and the next query re-files that subtree's boxes and leaves those
 entries in `loose` — a short list every query scans, which the stamp keeps from
 double-reporting against the cells they are still filed in. Past
 `QUERY_MAX_LOOSE` it gives up and rebuilds, because a linear scan stops being
 the cheaper answer.

 Everything that is *not* one subtree moving still rebuilds, and that list is
 the whole of the contract: adding a node, removing one, re-parenting one, and
 `Node.collides` changing. Toggling `Node.visible` costs nothing at all — see
 `Scene.query_node`, which tests it when it answers.

 ## The grid is a counting sort, not a hash of lists

 `starts` and `items` are the classic two-array bucket layout: one pass to count
 how many entries fall in each cell, a prefix sum, one pass to place them. Two
 flat `List{uint}`s that are `clear()`ed and refilled, so a rebuild allocates
 nothing after the first one.

 A `HashMap{sz, List{sz}}` — the shape `SpatialHash3D` uses — would allocate a
 list per occupied cell on every rebuild and free it on the next, which is
 exactly the churn a per-burst rebuild cannot afford. It earns its keep in the
 solver, where the same cells persist across thousands of steps.

 ## Big things are not in the grid

 A ground plane, a terrain mesh or a level shell covers the whole world, and
 smearing its index across every cell would make every query find it in every
 cell and discard all but one. Those go in `oversized` and are tested once per
 query — the same split `SpatialHash3D.is_large` makes, and for the same reason.
*>
module three;

import std::collections::list;
import std::math;
import std::math::vector;
import std::math::matrix;
import collision;

<*
 One drawable node and the world box that bounds it.

 The box is the mesh's local bounds through the node's world matrix — the
 transformed corners, not the transformed vertices. Conservative, which is what
 a broad phase wants: see `Scene.rebuild_query_index` for the measurement that
 chose it.
*>
struct QueryEntry
{
	NodeId node;
	collision::Aabb3 box;
}

<*
 How many cells an entry may cover and still go into the grid.

 64 is an 8x8x8 region. The cell size is chosen from the scene, so this is a
 statement about how much bigger than its neighbours a thing may be before
 spreading it is worse than testing it — not a statement about world units.
*>
const uint QUERY_MAX_CELLS = 64;

// Per axis, and a total. Both are there so that a scene with one node a
// kilometre from the rest cannot ask for a billion cells: the cell size is
// grown until the grid fits instead.
const int QUERY_MAX_DIM = 128;
const int QUERY_MAX_TOTAL = 1 << 18;

<*
 How many entries may be loose before a rebuild is the cheaper answer.

 Every query scans the loose list from end to end, where a rebuild is paid once
 and then costs queries nothing. A hundred is well inside the range where the
 scan wins — the case this exists for is a handful of characters sweeping
 between writes — and well short of the crowd that should be moved with
 `three.batch` and asked about afterwards.
*>
const sz QUERY_MAX_LOOSE = 128;

<*
 The broad phase over a scene's drawable nodes.

 Every list here is `clear()`ed and refilled by `rebuild`, so a scene that
 queries every frame allocates once and then never again.
*>
struct QueryIndex
{
	List{QueryEntry} entries;

	// The bucket layout. `starts` has one more element than there are cells;
	// `items` holds entry indices, grouped by cell.
	List{uint} starts;
	List{uint} items;

	// Entries too big for the grid — see the header.
	List{uint} oversized;

	<*
	 Which query last looked at each entry, so a query that walks several cells
	 reports a thing that straddles them once.

	 A stamp rather than a cleared bool array: clearing is O(entries) per query
	 and the whole point of the grid is that a query is O(what is near). The
	 counter is a `uint` and is bumped once per query, so it wraps after four
	 billion queries — at which point the first query after the wrap may miss a
	 duplicate. `rebuild` resets it, which in practice happens constantly.
	*>
	List{uint} stamp;
	uint stamp_now;

	<*
	 Entries whose node moved since the last rebuild, scanned linearly.

	 **The dirty set `plan.md` §17 asked for.** A rebuild is the right *answer*
	 to a node moving — the entry really does have a new box — at the wrong
	 *price*: one moved node re-filed all four hundred and thirty of them, so a
	 fixed step that moved eleven characters between its sweeps cost 29.2 ms
	 against 5.9 ms for the same step with every write deferred. That is a rule
	 a script should not have to know, and it breaks down the moment gameplay
	 legitimately has to move something and then ask about it.

	 A moved entry has its box rewritten in place and its index pushed here. It
	 is left filed in the cells it used to cover, which is safe in both
	 directions: a cell it no longer overlaps rejects it on the box test, and a
	 cell it now overlaps but is not filed in is reached by this scan. The stamp
	 above is what stops it being reported twice.

	 Linear, so it is only cheaper than a rebuild while it is short — see
	 `QUERY_MAX_LOOSE`, which is where it gives up and rebuilds instead.
	*>
	List{uint} loose;
	// One flag per entry, so a node moved five times between two queries is one
	// entry in `loose` rather than five.
	List{char} is_loose;

	// The nodes `Scene.invalidate` was told moved, and have not been re-filed
	// yet. Subtree roots: moving a group moves everything under it, and the
	// setter was only shown the group.
	List{NodeId} moved;

	// Entry index per node slot, or -1. What turns "this node moved" into
	// "re-file entry 214" without a search. Rebuilt with the entries, and only
	// ever read while `current` holds — every path that can add, remove or
	// recycle a slot drops the index outright.
	List{int} slot_entry;

	float cell;
	int[<3>] origin;
	int[<3>] dims;

	bool current;
	bool open;
}

fn void QueryIndex.init(&self)
{
	if (self.open) return;
	// Heap-backed explicitly, for the reason `Scene.init` spells out: a
	// zero-valued List binds itself to the temp arena on its first push, and
	// this one outlives every pool in the process.
	self.entries.init(mem, 64);
	self.starts.init(mem, 64);
	self.items.init(mem, 64);
	self.oversized.init(mem, 8);
	self.stamp.init(mem, 64);
	self.loose.init(mem, 16);
	self.is_loose.init(mem, 64);
	self.moved.init(mem, 16);
	self.slot_entry.init(mem, 64);
	self.open = true;
}

fn void QueryIndex.free(&self)
{
	if (!self.open) return;
	self.entries.free();
	self.starts.free();
	self.items.free();
	self.oversized.free();
	self.stamp.free();
	self.loose.free();
	self.is_loose.free();
	self.moved.free();
	self.slot_entry.free();
	self.open = false;
	self.current = false;
}

<*
 Throw the index away: the next query rebuilds from scratch.

 One place, so that "the index is stale" and "there is nothing pending to
 re-file" are set together. A rebuild subsumes every outstanding move, and a
 `moved` list left behind it would re-file entries the rebuild had just filed
 correctly — against a `slot_entry` map that no longer describes the same
 entries.
*>
fn void QueryIndex.drop(&self)
{
	self.current = false;
	if (self.open) self.moved.clear();
}

<*
 Remember that this node's subtree moved, or give up and rebuild.

 Called by `Scene.invalidate` for the changes whose extent is one subtree — a
 transform setter, the animation player, the physics write-back. Anything
 whose extent is not one subtree drops the index instead; see `Scene.invalidate`.
*>
fn void QueryIndex.note_moved(&self, NodeId id)
{
	if (!self.current) return;
	// Past the cap the linear scan the re-file leaves behind costs more than the
	// rebuild it saved. Counted against the same number as `loose` because one
	// pending node is at least one loose entry.
	if (self.moved.len() + self.loose.len() >= QUERY_MAX_LOOSE)
	{
		self.drop();
		return;
	}
	self.moved.push(id);
}

fn int[<3>] QueryIndex.cell_of(&self, Vec3 point)
{
	return {
		(int)math::floor(point.x / self.cell) - self.origin.x,
		(int)math::floor(point.y / self.cell) - self.origin.y,
		(int)math::floor(point.z / self.cell) - self.origin.z,
	};
}

fn int[<3>] QueryIndex.clamp_cell(&self, int[<3>] cell)
{
	return {
		math::clamp(cell.x, 0, self.dims.x - 1),
		math::clamp(cell.y, 0, self.dims.y - 1),
		math::clamp(cell.z, 0, self.dims.z - 1),
	};
}

fn int QueryIndex.key(&self, int x, int y, int z) @inline
{
	return (z * self.dims.y + y) * self.dims.x + x;
}

<*
 `count` zeroes in a list that already exists, without freeing its storage.

 `List` has `reserve` and `push` and no `resize`, and a rebuild wants a slot per
 cell filled with a count of zero. Reserving first is what keeps this from being
 a doubling walk on every rebuild.
*>
fn void zero_fill(List{uint}* list, sz count)
{
	list.clear();
	list.reserve(count);
	for (sz i = 0; i < count; i++) list.push(0);
}

<*
 Bring the index up to date, if it is not.

 Cheap when nothing moved — one bool — which is what makes it safe to call at
 the top of every query rather than making callers remember to.

 **Three states rather than two since §17's fixes.** The index is current; or
 some nodes moved and their entries can be re-filed, which is what a gameplay
 step that moves a character and then asks about it does; or it is gone and has
 to be rebuilt. The last case is what every structural change — an add, a
 removal, a re-parenting, a node joining the query set — still costs.

 The `matrices_current` test is a backstop rather than the mechanism. Every
 writer that clears it goes through `invalidate`, which either drops this index
 or records the move, so reaching this line with the index current and the
 matrices stale means a fourth writer appeared that neither of those knows
 about — and rebuilding is the answer that is merely slow rather than wrong.
*>
fn void Scene.ensure_query_index(&self, Assets* assets)
{
	if (!self.query.current)
	{
		self.rebuild_query_index(assets);
		return;
	}
	if (self.query.moved.len() > 0)
	{
		self.refile_moved(assets);
		return;
	}
	if (!self.matrices_current) self.rebuild_query_index(assets);
}

<*
 Rewrite the boxes of everything that moved, and leave those entries loose.

 The cheap half of `ensure_query_index` — see `QueryIndex.loose` for why
 leaving them out of the grid rather than re-bucketing them is both correct and
 the point. Cost is the moved subtrees, not the scene.
*>
fn void Scene.refile_moved(&self, Assets* assets)
{
	// Not optional and not free the first time: the boxes about to be written
	// are `node.world` through the mesh bounds, and `node.world` is what this
	// walk produces. It is the same walk the rebuild would have done.
	self.update_world_matrices();

	QueryIndex* index = &self.query;
	if (assets != null)
	{
		// Copied out: `refile_branch` takes `&self` and the list is a field of
		// it, so iterating it in place is the habit that stops being safe the
		// day something pushes to it mid-walk.
		sz count = index.moved.len();
		for (sz i = 0; i < count; i++) self.refile_branch(assets, index.moved[i]);
	}
	index.moved.clear();
}

fn void Scene.refile_branch(&self, Assets* assets, NodeId id)
{
	Node* node = self.node(id);
	if (node == null) return;

	self.refile_entry(assets, id, node);

	// Read through `self.nodes` per step for `update_branch`'s reason: the
	// recursion takes `&self`, so a pointer taken before it is not one to
	// index through afterwards.
	sz count = node.children.len();
	for (sz i = 0; i < count; i++) self.refile_branch(assets, self.nodes[id.index].children[i]);
}

fn void Scene.refile_entry(&self, Assets* assets, NodeId id, Node* node)
{
	QueryIndex* index = &self.query;
	if ((sz)id.index >= index.slot_entry.len()) return;

	int at = index.slot_entry[(sz)id.index];
	if (at < 0) return;

	QueryEntry* entry = &index.entries[(sz)at];
	// A slot that was recycled is a different node, and recycling a slot goes
	// through `create_slot`, which drops the whole index — so this cannot fire
	// today. It is here because being wrong about it would be a query answering
	// with a stranger's box, which is a bug nothing would attribute to this.
	if (entry.node != id) return;

	GpuMesh* mesh = assets.mesh(node.asset, node.mesh);
	if (mesh == null || mesh.bvh == null) return;

	entry.box = mesh.bounds.transform_matrix(node.world);
	if (index.is_loose[(sz)at] != 0) return;
	index.is_loose[(sz)at] = 1;
	index.loose.push((uint)at);
}

fn void Scene.rebuild_query_index(&self, Assets* assets)
{
	self.query.init();
	self.update_world_matrices();

	QueryIndex* index = &self.query;
	index.entries.clear();
	index.oversized.clear();
	index.items.clear();
	index.starts.clear();
	index.stamp.clear();
	index.loose.clear();
	index.is_loose.clear();
	index.moved.clear();
	index.stamp_now = 0;
	index.current = true;

	// One slot per node, -1 until an entry claims it. Sized to the pool rather
	// than to the entries because it is indexed by slot — see `slot_entry`.
	index.slot_entry.clear();
	index.slot_entry.reserve(self.nodes.len());
	for (sz i = 0; i < self.nodes.len(); i++) index.slot_entry.push(-1);

	if (assets == null)
	{
		index.dims = { 0, 0, 0 };
		return;
	}

	// Pass one: the entries, and the world box around all of them.
	collision::Aabb3 world = collision::NEW_AABB3;
	Vec3 extent_total = { 0, 0, 0 };
	foreach (slot, &node : self.nodes)
	{
		if (!node.alive) continue;
		if (!node.asset.is_set() || node.mesh == NO_MESH) continue;
		// **Where `collides` is spent** — `plan.md` §17. Filed out here rather
		// than tested at answer time the way `visible` is, because the two are
		// different kinds of flag: visibility is toggled per frame by gameplay
		// and the index must survive it, where this one says what a piece of
		// geometry *is* and is set when it is authored. Keeping decoration out
		// of the index entirely is what makes a hundred grass tufts free rather
		// than merely rejected a hundred times.
		if (!node.collides) continue;

		GpuMesh* mesh = assets.mesh(node.asset, node.mesh);
		// No tree is no narrow phase, and a broad-phase hit nothing can refine
		// is worse than an absence: `raycast` skipped these already.
		if (mesh == null || mesh.bvh == null) continue;

		// `mesh.bounds.transform_matrix`, not `world_mesh_bounds`. The second
		// transforms every *vertex* and is what `Scene.bounds` needs, because a
		// shadow fit around a conservative box wastes texels; a broad phase
		// wants the cheap one, and a box that is slightly too big costs a
		// narrow-phase test that rejects. Measured: 65 ns a node against 12,
		// on the rebuild that a moving scene pays once per query burst.
		collision::Aabb3 box = mesh.bounds.transform_matrix(node.world);
		index.slot_entry[slot] = (int)index.entries.len();
		index.entries.push({ .node = { .index = (uint)slot, .generation = node.generation }, .box = box });
		world.expand_by_point(box.min);
		world.expand_by_point(box.max);
		extent_total += box.size();
	}

	sz count = index.entries.len();
	zero_fill(&index.stamp, count);
	index.is_loose.clear();
	index.is_loose.reserve(count);
	for (sz i = 0; i < count; i++) index.is_loose.push(0);

	if (count == 0)
	{
		index.dims = { 0, 0, 0 };
		return;
	}

	// The cell size. Two floors, and both matter: an average object's own size,
	// because a cell smaller than the things in it puts every object in many
	// cells for no selectivity; and the span divided by the per-axis cap, which
	// is what stops one far-flung node from asking for a grid nobody can hold.
	Vec3 span = world.size();
	Vec3 mean = extent_total * (1.0f / (float)count);
	float cell = math::max(math::max(mean.x, math::max(mean.y, mean.z)), 1e-4f);

	float longest = math::max(span.x, math::max(span.y, span.z));
	cell = math::max(cell, longest / (float)QUERY_MAX_DIM);

	int[<3>] dims;
	// Grown rather than clamped, so the grid always covers the whole world: a
	// clamped dimension would leave nodes outside the array with nowhere to be
	// filed, and they would be invisible to every query rather than merely
	// coarsely filed.
	while (true)
	{
		dims = {
			math::max(1, (int)math::ceil(span.x / cell) + 1),
			math::max(1, (int)math::ceil(span.y / cell) + 1),
			math::max(1, (int)math::ceil(span.z / cell) + 1),
		};
		long total = (long)dims.x * (long)dims.y * (long)dims.z;
		if (total <= QUERY_MAX_TOTAL) break;
		cell *= 2.0f;
	}

	index.cell = cell;
	index.dims = dims;
	index.origin = {
		(int)math::floor(world.min.x / cell),
		(int)math::floor(world.min.y / cell),
		(int)math::floor(world.min.z / cell),
	};

	int cells = dims.x * dims.y * dims.z;
	zero_fill(&index.starts, (sz)cells + 1);

	// Pass two: count. An entry that covers too many cells is set aside here and
	// counted nowhere, which is what keeps it out of `items` in pass four.
	foreach (i, entry : index.entries)
	{
		int[<3>] lo = index.clamp_cell(index.cell_of(entry.box.min));
		int[<3>] hi = index.clamp_cell(index.cell_of(entry.box.max));
		long covered = (long)(hi.x - lo.x + 1) * (long)(hi.y - lo.y + 1) * (long)(hi.z - lo.z + 1);
		if (covered > (long)QUERY_MAX_CELLS)
		{
			index.oversized.push((uint)i);
			continue;
		}
		for (int z = lo.z; z <= hi.z; z++)
		{
			for (int y = lo.y; y <= hi.y; y++)
			{
				for (int x = lo.x; x <= hi.x; x++) index.starts[(sz)index.key(x, y, z) + 1]++;
			}
		}
	}

	// Pass three: the prefix sum, which turns the counts into where each cell's
	// run begins.
	for (sz i = 1; i < index.starts.len(); i++) index.starts[i] += index.starts[i - 1];

	zero_fill(&index.items, (sz)index.starts[index.starts.len() - 1]);

	// Pass four: place. `fill` walks the same counts a second time, using a copy
	// of the starts as a moving cursor — which is why the cursor is read out of
	// `starts` and written back, and why `starts` is one longer than the cell
	// count: the run for cell k is `starts[k] .. starts[k + 1]` and stays so.
	List{uint} cursor;
	cursor.tinit((sz)cells);
	for (int i = 0; i < cells; i++) cursor.push(index.starts[(sz)i]);

	foreach (i, entry : index.entries)
	{
		int[<3>] lo = index.clamp_cell(index.cell_of(entry.box.min));
		int[<3>] hi = index.clamp_cell(index.cell_of(entry.box.max));
		long covered = (long)(hi.x - lo.x + 1) * (long)(hi.y - lo.y + 1) * (long)(hi.z - lo.z + 1);
		if (covered > (long)QUERY_MAX_CELLS) continue;
		for (int z = lo.z; z <= hi.z; z++)
		{
			for (int y = lo.y; y <= hi.y; y++)
			{
				for (int x = lo.x; x <= hi.x; x++)
				{
					sz k = (sz)index.key(x, y, z);
					index.items[(sz)cursor[k]] = (uint)i;
					cursor[k]++;
				}
			}
		}
	}
}

<*
 Whether this entry is worth reporting, and the node behind it.

 Re-resolved through `Scene.node` rather than trusted, because the index is a
 snapshot: a node killed since the last rebuild has a bumped generation and this
 is where that is caught. Invisible nodes are skipped here rather than at build
 time, so toggling `visible` never costs a rebuild — see `Scene.raycast` for why
 invisible means "not found".

 **That sentence was a lie until §17's fix**, and it is worth saying which half
 was wrong: this end was always right, and `Scene.set_visible` went through
 `mark_moved` and threw the index away anyway. Measured at 32.7 ms a fixed step
 against 5.9 ms, on eleven characters that hid themselves around each sweep
 because `IgnoreSet` did not exist yet. `Scene.set_visible` now propagates
 `world_visible` itself and leaves this index alone, which is what makes the
 answer-time test here worth having.

 `collides` is deliberately *not* tested here — see `rebuild_query_index` for
 why that one is filed out at build time instead.
*>
fn Node* Scene.query_node(&self, QueryEntry entry)
{
	Node* node = self.node(entry.node);
	if (node == null || !node.world_visible) return null;
	if (!node.asset.is_set() || node.mesh == NO_MESH) return null;
	return node;
}

<*
 Every drawable node whose world box overlaps `box`.

 **Writes into a slice the caller owns and answers with how many it wrote**,
 which is the shape `notes.md` §17 measured as the only one whose cost stays
 flat as the count grows. A slice that is too short is filled and the count is
 the slice's length — the caller is told what fits, never handed a partial
 answer that reads as a complete one, because the count and the slice length
 being equal is exactly the signal "there may be more".

 The test is box against box, so this is a *broad-phase* answer: a node whose
 box overlaps and whose triangles do not is reported. That is the honest
 semantic for the question — "what is around here" — and the narrow phase, if
 one is wanted, is `raycast` or `sweep`.
*>
macro void Scene.@each_in_box(&self, Assets* assets, collision::Aabb3 box; @body(NodeId node, collision::Aabb3 world))
{
	self.ensure_query_index(assets);
	QueryIndex* index = &self.query;
	index.stamp_now++;

	foreach (i : index.oversized)
	{
		QueryEntry entry = index.entries[(sz)i];
		index.stamp[(sz)i] = index.stamp_now;
		if (!entry.box.collides(box)) continue;
		if (self.query_node(entry) == null) continue;
		@body(entry.node, entry.box);
	}

	// The entries that moved since the last rebuild, before the grid walk so
	// the stamp keeps the walk from reporting them a second time out of the
	// cells they used to be filed in. See `QueryIndex.loose`.
	foreach (i : index.loose)
	{
		if (index.stamp[(sz)i] == index.stamp_now) continue;
		QueryEntry entry = index.entries[(sz)i];
		index.stamp[(sz)i] = index.stamp_now;
		if (!entry.box.collides(box)) continue;
		if (self.query_node(entry) == null) continue;
		@body(entry.node, entry.box);
	}

	if (index.dims.x != 0)
	{
		int[<3>] lo = index.clamp_cell(index.cell_of(box.min));
		int[<3>] hi = index.clamp_cell(index.cell_of(box.max));
		for (int z = lo.z; z <= hi.z; z++)
		{
			for (int y = lo.y; y <= hi.y; y++)
			{
				for (int x = lo.x; x <= hi.x; x++)
				{
					sz k = (sz)index.key(x, y, z);
					for (sz at = (sz)index.starts[k]; at < (sz)index.starts[k + 1]; at++)
					{
						sz i = (sz)index.items[at];
						if (index.stamp[i] == index.stamp_now) continue;
						index.stamp[i] = index.stamp_now;

						QueryEntry entry = index.entries[i];
						if (!entry.box.collides(box)) continue;
						if (self.query_node(entry) == null) continue;
						@body(entry.node, entry.box);
					}
				}
			}
		}
	}
}

fn uint Scene.query_box(&self, Assets* assets, collision::Aabb3 box, NodeId[] out)
{
	if (out.len == 0) return 0;

	uint found = 0;
	self.@each_in_box(assets, box; NodeId node, collision::Aabb3 world)
	{
		// The slice is filled and then ignored rather than the walk being cut
		// short: a macro body cannot break its caller's loop, and a cell walk
		// that has already found more than was asked for is a few cell reads,
		// not a narrow phase. The count still stops at the slice's length,
		// which is the contract.
		if (found < out.len) out[found++] = node;
	};
	return found;
}

<*
 Every drawable node whose world box reaches within `radius` of `centre`.

 The box test above with a sphere test after it, which is the right order: the
 cell walk is a box walk however the caller asked the question, and a box that
 does not overlap cannot contain a point of the sphere.

 The sphere is tested against the node's *box*, not against its triangles — the
 same broad-phase honesty `query_box` documents.
*>
fn uint Scene.overlap_sphere(&self, Assets* assets, Vec3 centre, float radius, NodeId[] out)
{
	if (out.len == 0) return 0;

	float r = math::max(radius, 0.0f);
	Vec3 reach = { r, r, r };
	collision::Aabb3 box = { centre - reach, centre + reach };
	float r_sq = r * r;

	// One pass, with the exact test where the box is already in hand. Written
	// as a filter over `query_box`'s answer first, which needed the world box
	// back for each hit and so had to find it again — a linear scan of the
	// entry list per candidate, which is quadratic in a scene where the query
	// is wide. The macro yields the box because this is the caller that needs
	// it, and it costs nothing to hand over what has just been tested.
	uint found = 0;
	self.@each_in_box(assets, box; NodeId node, collision::Aabb3 world)
	{
		if (found < out.len)
		{
			// The closest point on the box to the centre: the exact
			// box-versus-sphere test, rather than the box-versus-box one the
			// cell walk did. Without it a query of radius r reports everything
			// in a 2r cube, and the corners of that cube are 73% further away
			// than the radius asked for.
			Vec3 nearest = math::min(math::max(centre, world.min), world.max);
			if ((nearest - centre).length_sq() <= r_sq) out[found++] = node;
		}
	};
	return found;
}

<*
 The ray-versus-one-instance narrow phase, lifted out of `Scene.raycast`.

 Every word of the transform argument that used to live inline in `raycast` is
 still in that function's doc block; this is the same arithmetic, called from
 three places now instead of one.

 @param limit : `Ignore hits further than this along the ray. float::max for no limit.`
 @return `Whether it hit, with the hit written to out.`
*>
fn bool Scene.ray_hits_node(&self, Assets* assets, NodeId id, collision::Ray ray, float limit, Hit* out)
{
	Node* node = self.node(id);
	if (node == null) return false;

	GpuMesh* mesh = assets.mesh(node.asset, node.mesh);
	if (mesh == null || mesh.bvh == null) return false;

	Matrix4f inverse_world = invert(node.world);

	Vec3 local_origin = transform_point(inverse_world, ray.origin);
	Vec3 local_direction = transform_direction(inverse_world, ray.direction);

	float length = local_direction.length();
	if (length < 1e-12f) return false;

	collision::Ray local_ray = { .origin = local_origin, .direction = local_direction / length };
	collision::HitInfo narrow = mesh.bvh.ray_intersects(local_ray);
	if (!narrow.collided) return false;

	float distance = narrow.depth / length;
	if (distance >= limit) return false;

	*out = {
		.hit = true,
		.node = id,
		.asset = node.asset,
		.mesh = node.mesh,
		.distance = distance,
		.point = ray.origin + ray.direction * distance,
		.normal = transform_direction(node.normal, narrow.normal).normalize(),
	};
	return true;
}

<*
 Walk the cells a ray passes through, nearest first.

 Amanatides and Woo's 3D DDA. **The order is the whole point**: a raycast that
 wants only the closest hit can stop at the end of the first cell that produced
 one, because nothing in a later cell can be nearer than the near wall of that
 cell — which is what turns a query that is linear in the scene into one that is
 linear in the *distance travelled*. A ground ray from a character's feet
 touches two or three cells whatever else is in the level.

 The body is run once per candidate entry index, possibly more than once for an
 entry that straddles cells; the caller stamps.

 `@body(uint entry, float cell_near)` — `cell_near` is the ray parameter at
 which this cell was entered, so a caller can stop once its best hit is nearer
 than the cell it is about to look at.
*>
macro void QueryIndex.@walk_ray(&self, collision::Ray ray, float max_distance; @body(uint entry, float cell_near))
{
	if (self.dims.x != 0)
	{
		// Clip the ray to the grid first. Starting the DDA outside it would
		// step through empty space one cell at a time until it arrived, which
		// for a camera ray in a small scene is most of the loop's iterations.
		float enter = 0.0f;
		float leave = max_distance;
		Vec3 grid_min = {
			(float)self.origin.x * self.cell,
			(float)self.origin.y * self.cell,
			(float)self.origin.z * self.cell,
		};
		Vec3 grid_max = grid_min + (Vec3) {
			(float)self.dims.x * self.cell,
			(float)self.dims.y * self.cell,
			(float)self.dims.z * self.cell,
		};

		bool misses = false;
		for (int axis = 0; axis < 3; axis++)
		{
			float direction = ray.direction[axis];
			float origin = ray.origin[axis];
			float lo = grid_min[axis];
			float hi = grid_max[axis];
			if (math::abs(direction) < 1e-12f)
			{
				if (origin < lo || origin > hi) { misses = true; break; }
				continue;
			}
			float t0 = (lo - origin) / direction;
			float t1 = (hi - origin) / direction;
			if (t0 > t1) { float swap = t0; t0 = t1; t1 = swap; }
			enter = math::max(enter, t0);
			leave = math::min(leave, t1);
			if (enter > leave) { misses = true; break; }
		}

		if (!misses)
		{
			// A hair inside, so the entry point does not land exactly on a cell
			// wall and floor into the cell before the grid.
			Vec3 at = ray.origin + ray.direction * (enter + 1e-4f);
			int[<3>] cell = self.clamp_cell(self.cell_of(at));

			int[<3>] step;
			Vec3 next;
			Vec3 delta;
			for (int axis = 0; axis < 3; axis++)
			{
				float direction = ray.direction[axis];
				if (math::abs(direction) < 1e-12f)
				{
					step[axis] = 0;
					next[axis] = float::max;
					delta[axis] = float::max;
					continue;
				}
				step[axis] = direction > 0 ? 1 : -1;
				float wall = (float)(self.origin[axis] + cell[axis] + (direction > 0 ? 1 : 0)) * self.cell;
				next[axis] = (wall - ray.origin[axis]) / direction;
				delta[axis] = self.cell / math::abs(direction);
			}

			float near = enter;
			while (near <= leave)
			{
				sz k = (sz)self.key(cell.x, cell.y, cell.z);
				for (sz at_item = (sz)self.starts[k]; at_item < (sz)self.starts[k + 1]; at_item++)
				{
					@body(self.items[at_item], near);
				}

				// The axis whose wall is nearest is the one crossed next.
				int axis = 0;
				if (next.y < next.x) axis = 1;
				if (next[axis] > next.z) axis = 2;
				near = next[axis];
				cell[axis] += step[axis];
				next[axis] += delta[axis];
				if (cell[axis] < 0 || cell[axis] >= self.dims[axis]) break;
			}
		}
	}

	// The big things, after the walk rather than before it: they are tested
	// against the whole ray, so they have no cell to be ordered by and a caller
	// stopping early must have seen them. `float::max` says "no ordering
	// information", which every caller reads as "cannot be skipped".
	foreach (i : self.oversized) @body(i, 0.0f);
	// The moved ones, for the same reason and with the same disclaimer: they
	// are filed in the cells they used to cover, so the walk cannot be trusted
	// to have reached them. The caller's stamp is what stops the ones it did
	// reach being tested twice.
	foreach (i : self.loose) @body(i, 0.0f);
}

<*
 Every drawable node the ray hits, in no particular order.

 `raycastAll`, and the verb a script wants when the nearest hit is not the
 answer — shooting through a window, listing what is under the cursor, a laser
 that stops at the first *solid* thing rather than at the first thing.

 Sorted by distance is deliberately **not** promised: sorting means holding
 every hit before answering, which is the shape this whole file exists to avoid.
 A caller that wants the nearest calls `raycast`, which is cheaper than sorting
 because it can stop.

 @param max_distance : `How far along the ray to look, in world units. Zero or less means no limit.`
*>
fn uint Scene.raycast_all(&self, Assets* assets, collision::Ray ray, float max_distance, Hit[] out)
{
	self.ensure_query_index(assets);
	if (out.len == 0 || assets == null) return 0;

	QueryIndex* index = &self.query;
	float limit = max_distance > 0.0f ? max_distance : float::max;

	uint found = 0;
	index.stamp_now++;

	index.@walk_ray(ray, limit; uint i, float cell_near)
	{
		if (found < out.len && index.stamp[(sz)i] != index.stamp_now)
		{
			index.stamp[(sz)i] = index.stamp_now;
			QueryEntry entry = index.entries[(sz)i];
			collision::HitInfo broad = entry.box.intersect_ray(ray);
			if (broad.collided && broad.depth <= limit && self.query_node(entry) != null)
			{
				Hit hit;
				if (self.ray_hits_node(assets, entry.node, ray, limit, &hit)) out[found++] = hit;
			}
		}
	};
	return found;
}

// ============================================================================
// The sweep, and the triangle narrow phase both it and the character use
// ============================================================================

<*
 What a swept capsule ran into.

 `fraction` is where along the motion it happened, in [0, 1], which is the
 number a caller integrating a movement wants: the safe position is
 `from + (to - from) * fraction`. `distance` is the same thing in world units,
 for a caller who was thinking in metres.

 `normal` points **out of the surface, towards the capsule** — the direction a
 slide projects against and the direction a ground test compares with up. It is
 derived from the closest pair rather than from the triangle's winding, so a
 mesh with inconsistent winding still slides the right way.
*>
struct SweepHit
{
	bool hit;
	NodeId node;
	float fraction;
	float distance;
	Vec3 point;
	Vec3 normal;
}

<*
 How many advancement steps a sweep may take before giving up.

 With the directional bound below the loop converges in a handful of steps for
 anything a character does, so the cap is a backstop rather than a budget. Past
 it the sweep answers "no hit", which is the safe direction — the caller moves
 the whole way and the next frame's depenetration catches it — where answering
 "hit at the last t" would stop a character dead against a wall it was sliding
 along.
*>
const int SWEEP_MAX_STEPS = 24;

// Below this the closing rate is treated as zero: the surface is being moved
// along rather than towards, and no amount of travel will reach it. It is what
// makes a capsule resting on a floor able to walk.
const float SWEEP_CLOSING_EPSILON = 1e-4f;

<*
 How close to the clearance counts as touching it, relative to the length of
 the motion.

 **Without a tolerance here the loop never terminates on a hit.** Each step
 advances by exactly the gap, so the capsule approaches contact asymptotically
 in floating point and the test `distance <= clearance` is left one ulp short —
 for ever, or rather for `SWEEP_MAX_STEPS`, after which the sweep answers "no
 hit" for a wall it is a ten-thousandth of a millimetre from. The failure is
 not subtle when it happens (a character walks through a wall) and it is
 completely invisible in the arithmetic, which is why the constant is named.

 Scaled by the motion, because the arithmetic's own noise floor is: a
 hundred-metre sweep resolves its position to about a millimetre in float, and
 a fixed absolute tolerance below that is no tolerance at all.
*>
const float SWEEP_TOUCH = 1e-5f;

<*
 The closest pair between a segment and a triangle.

 The five candidates that a segment-versus-triangle minimum can be attained at:
 each endpoint against the triangle (vertex-face, and vertex-edge and
 vertex-vertex as its degenerate cases), and the segment against each of the
 three edges (edge-edge). That set is exhaustive for two convex polytopes that
 do not intersect, which is the case conservative advancement keeps it in.

 Intersection is handled separately and first, because none of the five sees it:
 a segment that passes clean through the triangle has both endpoints away from
 it and every edge pair positive, so the minimum comes back positive and the
 sweep would step straight through.
*>
struct SegmentTriangle
{
	float distance;
	Vec3 on_segment;
	Vec3 on_triangle;
}

fn SegmentTriangle segment_triangle_closest(Vec3 a, Vec3 b, collision::TriangleVerts tri)
{
	Vec3 v0 = tri[0];
	Vec3 v1 = tri[1];
	Vec3 v2 = tri[2];

	// Does the segment cross the triangle? The plane test first, because it is
	// two dot products and rejects almost every triangle a sweep looks at.
	Vec3 face = (v1 - v0).cross(v2 - v0);
	float area_sq = face.length_sq();
	if (area_sq > 1e-16f)
	{
		float da = face.dot(a - v0);
		float db = face.dot(b - v0);
		if ((da < 0.0f) != (db < 0.0f))
		{
			float t = da / (da - db);
			Vec3 crossing = a + (b - a) * t;
			Vec3 inside = collision::closest_point_on_triangle(crossing, v0, v1, v2);
			// The plane crossing is inside the triangle exactly when the
			// triangle's own closest point to it is itself. The tolerance is
			// squared and generous: a crossing a micron outside an edge is
			// caught by the edge candidates below at a distance of a micron,
			// which is the same answer.
			if ((inside - crossing).length_sq() < 1e-12f)
			{
				return { .distance = 0.0f, .on_segment = crossing, .on_triangle = crossing };
			}
		}
	}

	SegmentTriangle best = { .distance = float::max };

	Vec3[2] ends = { a, b };
	foreach (end : ends)
	{
		Vec3 on_tri = collision::closest_point_on_triangle(end, v0, v1, v2);
		float d = (end - on_tri).length();
		if (d < best.distance) best = { .distance = d, .on_segment = end, .on_triangle = on_tri };
	}

	Vec3[3] edge_a = { v0, v1, v2 };
	Vec3[3] edge_b = { v1, v2, v0 };
	for (int i = 0; i < 3; i++)
	{
		Vec3 on_seg;
		Vec3 on_edge;
		collision::closest_points_segments(a, b, edge_a[i], edge_b[i], &on_seg, &on_edge);
		float d = (on_seg - on_edge).length();
		if (d < best.distance) best = { .distance = d, .on_segment = on_seg, .on_triangle = on_edge };
	}

	return best;
}

<*
 How many nodes one sweep may be told to ignore.

 Small on purpose. This is "the thing moving, and the two or three things it is
 allowed to pass through" — a crowd of exceptions is a `collides` flag or a
 layer, not an argument. Fixed rather than a list so an `IgnoreSet` is a value
 with no allocator and no lifetime, which is what lets it be a `MoveOptions`
 field and be copied down four call frames per sweep without anyone thinking
 about it.
*>
const usz MAX_IGNORED = 8;

<*
 The nodes a sweep leaves out, and everything under them.

 **A set of subtrees rather than one node** — `plan.md` §17. `gather_triangles`
 took a single `NodeId`, which is right only for a character that is one mesh:
 a character built out of a body, a head, two arms and two legs collided with
 its own chest, `hit` came back as one of its own boxes, and the capsule was
 thrown out along that normal — which reads as the controller being broken
 rather than as the contract being too narrow. Hiding the whole group for the
 duration of the move was the only workaround, and it cost the query index.

 Subtrees rather than nodes because that is what a character *is*, and because
 a leaf node is its own subtree — so one id in a set of one is exactly the old
 behaviour.
*>
struct IgnoreSet
{
	NodeId[MAX_IGNORED] nodes;
	usz count;
}

<*
 The set holding one node and its subtree, or an empty one for `NO_NODE`.
*>
fn IgnoreSet ignore_one(NodeId id)
{
	if (!id.is_set()) return {};
	IgnoreSet set;
	set.nodes[0] = id;
	set.count = 1;
	return set;
}

<*
 The set holding each of these nodes and its subtree.

 Ids past `MAX_IGNORED` are dropped rather than raising: this is called from the
 JS boundary with whatever a script passed, and the failure of dropping one is a
 sweep that collides with something it was asked to pass through — visible,
 local, and nothing like as bad as an exception out of the middle of a movement.
*>
fn IgnoreSet ignore_list(NodeId[] ids)
{
	IgnoreSet set;
	foreach (id : ids)
	{
		if (!id.is_set() || set.count >= MAX_IGNORED) continue;
		set.nodes[set.count++] = id;
	}
	return set;
}

<*
 Whether this node, or anything it hangs from, is in the set.

 Up the parent chain rather than down every ignored subtree, so the cost is the
 node's depth times the set's size — a handful of comparisons on the nodes a
 sweep actually reached — rather than anything in the size of what is ignored.
 `Scene.set_parent` refuses to make a cycle, so the walk terminates.
*>
fn bool Scene.ignored(&self, NodeId id, IgnoreSet set)
{
	if (set.count == 0) return false;

	NodeId at = id;
	while (at.is_set())
	{
		for (usz i = 0; i < set.count; i++) if (set.nodes[i] == at) return true;
		Node* node = self.node(at);
		if (node == null) break;
		at = node.parent;
	}
	return false;
}

<*
 Every triangle of every drawable node overlapping `box`, in **world** space.

 The triangles are transformed rather than the query shape being pushed into
 each mesh's local space, and that is the decision worth stating: a capsule is
 not a capsule any more under a non-uniform scale, so a sweep done in local
 space against a mesh scaled `(2, 1, 1)` would be testing an ellipsoid against
 the triangles and calling it a capsule. A triangle survives any affine
 transform as a triangle.

 The cost is per triangle rather than per mesh, which is the right way round
 here: a sweep gathers tens of triangles out of a tree, where the local-space
 version would have been one matrix inverse and then an answer that is wrong on
 exactly the meshes a level is built from.

 @param out : `Appended to, not cleared. The caller owns the list and its allocator.`
 @param skip : `Nodes to leave out, subtrees included — the character's own body. An empty set for none.`
*>
fn void Scene.gather_triangles(
	&self, Assets* assets, collision::Aabb3 box, IgnoreSet skip,
	List{collision::TriangleVerts}* out, List{NodeId}* owners
)
{
	if (assets == null) return;

	self.@each_in_box(assets, box; NodeId id, collision::Aabb3 world)
	{
		if (!self.ignored(id, skip))
		{
			Node* node = self.node(id);
			if (node != null)
			{
				GpuMesh* mesh = assets.mesh(node.asset, node.mesh);
				if (mesh != null && mesh.bvh != null)
				{
					// The world box pulled back into the mesh's own space. An
					// AABB through an inverse is conservative — it is the box
					// around the transformed corners — which is exactly what a
					// tree query wants: too many triangles is a slower narrow
					// phase and too few is a wall walked through.
					Matrix4f inverse_world = invert(node.world);
					collision::Aabb3 local = box.transform_matrix(inverse_world);

					sz before = out.len();
					mesh.bvh.query_all_triangles(local, out);
					for (sz i = before; i < out.len(); i++)
					{
						collision::TriangleVerts tri = out.get(i);
						out.set(i, {
							transform_point(node.world, tri[0]),
							transform_point(node.world, tri[1]),
							transform_point(node.world, tri[2]),
						});
						owners.push(id);
					}
				}
			}
		}
	};
}

<*
 Sweep a vertical capsule from `from` to `to` and answer with the first thing it
 touches.

 **This is the narrow phase the character controller is built out of**, which is
 why it lives here rather than beside the controller: `three.query.sweep` and
 `three.character` are then one implementation, and a wall a sweep reports and a
 wall the controller slides along cannot be two different walls.

 ## Conservative advancement, not a closed-form time of impact

 The loop is: measure the clearance between the capsule where it is and every
 triangle near it, move by the clearance, repeat. It can never tunnel — moving
 by the clearance cannot close a gap of the clearance, whatever direction the
 motion is in — and it needs no per-shape algebra, which is what makes it work
 unchanged against a triangle soup, a terrain and a scaled mesh.

 What it costs is iterations along a grazing path; see `SWEEP_MAX_STEPS` for
 what happens at the cap and why "no hit" is the safe answer there.

 ## The capsule is upright, and that is a decision

 `half_height` is measured from the centre to each hemisphere's centre, so a
 capsule is `2 * (half_height + radius)` tall overall. There is no orientation
 argument: everything this is for — a character, an agent, a probe — stands up,
 and an arbitrary axis would have to be carried through the ground test, the
 step-up and the slide, none of which mean anything for a capsule lying down.
 A `half_height` of zero is a sphere, and that is what `three.query.sweep` with
 no height asks for.

 @param radius : `The capsule's radius. Zero or less makes this a ray, and Scene.raycast is the faster way to ask that.`
 @param skin : `Extra clearance kept from every surface, in world units. A character uses a millimetre or two so it never rests exactly on a face.`
 @param skip : `Nodes to ignore, subtrees included — the moving body's own. An empty set for none.`
*>
fn SweepHit Scene.sweep_capsule(
	&self, Assets* assets, Vec3 from, Vec3 to,
	float radius, float half_height, float skin = 0.0f, IgnoreSet skip = {}
)
{
	SweepHit miss = { .hit = false, .fraction = 1.0f, .distance = 0.0f };
	if (assets == null) return miss;

	float r = math::max(radius, 0.0f);
	float half = math::max(half_height, 0.0f);
	float clearance = r + math::max(skin, 0.0f);

	Vec3 travel = to - from;
	float length = travel.length();

	// The box around the whole motion, both hemispheres and the clearance. Wide
	// by design: it is gathered once and reused for every step of the loop, so a
	// box that is too tight is a triangle that appears halfway through the sweep
	// and is never seen.
	Vec3 reach = { clearance, clearance + half, clearance };
	collision::Aabb3 box = { math::min(from, to) - reach, math::max(from, to) + reach };

	@pool()
	{
		List{collision::TriangleVerts} triangles;
		triangles.tinit(64);
		List{NodeId} owners;
		owners.tinit(64);
		self.gather_triangles(assets, box, skip, &triangles, &owners);

		if (triangles.len() == 0) return miss;

		bool still = length <= 1e-9f;
		Vec3 direction = still ? (Vec3) { 0, 0, 0 } : travel / length;
		float at = 0.0f;
		float touch = clearance + SWEEP_TOUCH * math::max(1.0f, length);

		for (int step = 0; step < SWEEP_MAX_STEPS; step++)
		{
			Vec3 centre = from + direction * at;
			Vec3 head = centre + (Vec3) { 0, half, 0 };
			Vec3 tail = centre - (Vec3) { 0, half, 0 };

			// The smallest distance the capsule may travel before *some*
			// triangle could be within reach. Conservative, per triangle, and
			// the minimum of them is the safe step.
			float soonest = float::max;
			bool blocked = false;
			SegmentTriangle best;
			Vec3 best_axis = { 0, 1, 0 };
			sz best_index = 0;

			foreach (i, tri : triangles)
			{
				SegmentTriangle pair = segment_triangle_closest(tail, head, tri);

				// The separating axis: the unit direction from the capsule to
				// the triangle. This is what makes the bound directional.
				Vec3 axis;
				if (pair.distance > 1e-6f)
				{
					axis = (pair.on_triangle - pair.on_segment) / pair.distance;
				}
				else
				{
					// Touching exactly, or already through, so there is no
					// separating direction left to measure. The triangle's own
					// plane is what remains, signed so it points the way the
					// capsule would have to go to reach it.
					axis = (tri[1] - tri[0]).cross(tri[2] - tri[0]);
					float n = axis.length();
					axis = n > 1e-9f ? axis / n : (Vec3) { 0, -1, 0 };
					if (axis.dot(direction) < 0.0f) axis = -axis;
				}

				// How fast the gap closes per unit travelled. For two convex
				// shapes the distance can shrink no faster than this, which is
				// what makes the step below safe.
				float closing = still ? 0.0f : direction.dot(axis);

				if (pair.distance <= touch)
				{
					// **Within reach, but only a contact the motion is pushing
					// INTO actually stops anything.** This is the line that
					// lets a character walk: a capsule resting on a floor is
					// permanently within the clearance of it, and a sweep that
					// called that a hit would consume the whole motion at
					// fraction zero, every frame, for ever. A floor underfoot
					// has a closing rate of nought for a horizontal step and is
					// therefore not in the way; a wall ahead has a positive one
					// and is.
					if (still || closing > SWEEP_CLOSING_EPSILON)
					{
						blocked = true;
						best = pair;
						best_axis = axis;
						best_index = i;
						break;
					}
					continue;
				}

				// Moving along it or away from it: no amount of travel on this
				// heading brings the capsule to this triangle.
				if (closing <= SWEEP_CLOSING_EPSILON) continue;

				float bound = (pair.distance - clearance) / closing;
				if (bound < soonest) soonest = bound;
			}

			if (blocked)
			{
				return {
					.hit = true,
					.node = owners[best_index],
					.fraction = still ? 0.0f : math::clamp(at / length, 0.0f, 1.0f),
					.distance = at,
					.point = best.on_triangle,
					// Out of the surface, towards the capsule — the direction a
					// slide projects against and a ground test compares with up.
					.normal = -best_axis,
				};
			}

			// Nothing can be reached at all, or nothing before the motion ends.
			if (soonest >= float::max || at + soonest >= length) return miss;

			// The whole bound, not a fraction of it: it can never overshoot the
			// true time of impact, so taking less of it only costs iterations —
			// and taking 95% of it, which this did until the resting-contact
			// case was found, leaves a geometric series that never arrives.
			at += soonest;
		}

		// Did not converge — see SWEEP_MAX_STEPS.
		return miss;
	};
}

<*
 The sphere case, which is what `three.query.sweep` asks for when no height was
 given. A capsule of zero half-height is a sphere; there is no second
 implementation.
*>
fn SweepHit Scene.sweep_sphere(&self, Assets* assets, Vec3 from, Vec3 to, float radius, IgnoreSet skip = {})
{
	return self.sweep_capsule(assets, from, to, radius, 0.0f, 0.0f, skip);
}
