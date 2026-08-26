<*
 Navigation and steering, as JavaScript sees them.

 ## Why the field is a handle and not an object

 `three.nav.field(goals)` hands back a number and
 `three.nav.direction(handle, point)` takes it — deliberately not the shape the
 rest of this API uses, where a host thing is wrapped in a JavaScript class.

 A field is one `float[]` per walkable cell — tens of thousands for a town — and
 the two things a script does with it are sample it and throw it away. Wrapping
 it would mean either copying that array into the engine on every read, or
 hanging host memory off a JS object whose collection the host cannot see. So a
 field is freed by `field.dispose()` and by `new three.Scene()`, and a handle to
 a freed one answers "unreachable" rather than reading released memory.

 The bake is dropped by `new three.Scene()` for the reason the physics bodies
 are: it was voxelized out of triangles that are gone, and a stale nav mesh is
 worse than none — an agent walks confidently through where a wall used to be,
 which reads as the pathfinder being broken rather than as the mesh being stale.
*>
module three;

import std::collections::list;
import std::math;
import std::math::vector;
import collision;
import qjs;

<*
 One solved flow field, with the slot reuse that keeps handles small.

 `live` rather than removing the entry, because a handle is the index: shifting
 the list would silently repoint every handle a script is holding.
*>
struct NavFieldSlot
{
	float[] values;
	bool live;
}

fn void JsRuntime.bind_nav_verbs(&self, qjs::Value host)
{
	self.bind(host, "navBake", &js_nav_bake, 11);
	self.bind(host, "navStats", &js_nav_stats, 0);
	self.bind(host, "navClear", &js_nav_clear, 0);
	self.bind(host, "navField", &js_nav_field, 3);
	self.bind(host, "navFieldFree", &js_nav_field_free, 1);
	self.bind(host, "navDirection", &js_nav_direction, 4);
	self.bind(host, "navCost", &js_nav_cost, 4);
	self.bind(host, "navSample", &js_nav_sample, 10);
	self.bind(host, "navPath", &js_nav_path, 9);
	self.bind(host, "steer", &js_steer, 14);
}

<*
 Frees the bake and every field over it.

 Called by `three.nav.clear()`, by a re-bake, and by `new three.Scene()`. The
 fields go with the mesh and not one at a time: they are sized to the grid's cell
 count, so a field kept across a re-bake would be the wrong length, and the
 length check in `NavMesh.solve` would silently make it unusable — a bug that
 looks like the pathfinder finding nothing.
*>
fn void JsRuntime.drop_nav(&self)
{
	foreach (&slot : self.nav_fields)
	{
		if (slot.values.len > 0) mem::free(slot.values);
		*slot = {};
	}
	self.nav_fields.clear();
	self.nav.free();
}

<*
 `navBake(cell, radius, height, slope, hasBounds, minX, minY, minZ, maxX, maxY, maxZ)`.

 Answers with the same object `navStats` does, or `null` when the region held no
 standing room — a real answer and not an error: an empty scene, a scene of
 walls, or a slope limit nothing in it is under.
*>
fn void js_nav_bake(
	qjs::ContextRef ctx, qjs::Value* this_val, int argc, qjs::Value* args, void* opaque, qjs::Value* out
) @local
{
	JsRuntime* self = (JsRuntime*)opaque;
	qjs::Context js = qjs::wrap(ctx);

	NavSettings settings = default_nav_settings();
	float cell = arg_float(&js, argc, args, 0);
	if (cell > 0.0f) settings.cell = cell;
	settings.agent_radius = math::max(arg_float(&js, argc, args, 1), 0.0f);
	settings.agent_height = math::max(arg_float(&js, argc, args, 2), 0.0f);
	settings.slope_limit = arg_float(&js, argc, args, 3);
	settings.has_bounds = arg_truth(&js, argc, args, 4);
	if (settings.has_bounds)
	{
		settings.bounds = {
			{ arg_float(&js, argc, args, 5), arg_float(&js, argc, args, 6), arg_float(&js, argc, args, 7) },
			{ arg_float(&js, argc, args, 8), arg_float(&js, argc, args, 9), arg_float(&js, argc, args, 10) },
		};
		settings.bounds.fix();
	}

	// Everything over the old grid goes first — see `drop_nav`.
	self.drop_nav();

	if (!self.pass.scene.bake_nav(&self.pass.assets, settings, &self.nav))
	{
		*out = qjs::null_value();
		return;
	}
	*out = nav_stats_value(self, &js);
}

fn qjs::Value nav_stats_value(JsRuntime* self, qjs::Context* js) @local
{
	if (!self.nav.usable()) return qjs::null_value();

	qjs::Value value = js.object();
	js.set_property(value, "cell", qjs::number_value(self.nav.settings.cell));
	js.set_property(value, "radius", qjs::number_value(self.nav.settings.agent_radius));
	js.set_property(value, "height", qjs::number_value(self.nav.settings.agent_height));
	js.set_property(value, "slope", qjs::number_value(self.nav.settings.slope_limit));
	// The three counts and the time are what decide whether baking is a
	// level-boundary operation or a loading-screen one, answerable for the
	// caller's own level rather than for a reference one.
	js.set_property(value, "voxels", qjs::number_value((double)self.nav.voxels));
	js.set_property(value, "solid", qjs::number_value((double)self.nav.solid_cells));
	js.set_property(value, "floor", qjs::number_value((double)self.nav.floor_cells));
	js.set_property(value, "walkable", qjs::number_value((double)self.nav.walkable_cells));
	// The two that say whether the bake is *usable* rather than what it cost.
	// Every counter above is a total, and a total cannot tell a level an agent can
	// cross from the same level cut into islands — see `NavMesh.components`.
	// `components > 1` is the signal a caller wants at bake time rather than after
	// the third agent stands still for no reason.
	js.set_property(value, "components", qjs::number_value((double)self.nav.components));
	js.set_property(value, "largest", qjs::number_value((double)self.nav.largest_component));
	js.set_property(value, "bakeMs", qjs::number_value(self.nav.bake_ms));
	js.set_property(value, "bounds", aabb_value(js, (collision::Aabb3) {
		self.nav.grid.origin,
		self.nav.grid.origin + (Vec3) {
			(float)(self.nav.grid.nx - 1) * self.nav.grid.cell,
			(float)(self.nav.grid.ny - 1) * self.nav.grid.cell,
			(float)(self.nav.grid.nz - 1) * self.nav.grid.cell,
		},
	}));
	return value;
}

fn void js_nav_stats(
	qjs::ContextRef ctx, qjs::Value* this_val, int argc, qjs::Value* args, void* opaque, qjs::Value* out
) @local
{
	JsRuntime* self = (JsRuntime*)opaque;
	qjs::Context js = qjs::wrap(ctx);
	*out = nav_stats_value(self, &js);
}

fn void js_nav_clear(
	qjs::ContextRef ctx, qjs::Value* this_val, int argc, qjs::Value* args, void* opaque, qjs::Value* out
) @local
{
	JsRuntime* self = (JsRuntime*)opaque;
	self.drop_nav();
	*out = qjs::undefined_value();
}

<*
 `navField(buffer, byteOffset, goalFloats)` — solve towards a set of goals and
 keep the answer.

 @return `A handle, or -1 when nothing was solved: no bake, no goals, or no goal on a walkable cell.`
*>
fn void js_nav_field(
	qjs::ContextRef ctx, qjs::Value* this_val, int argc, qjs::Value* args, void* opaque, qjs::Value* out
) @local
{
	JsRuntime* self = (JsRuntime*)opaque;
	qjs::Context js = qjs::wrap(ctx);

	if (!self.nav.usable())
	{
		*out = js.raise("three.nav.field() needs a baked mesh — call three.nav.bake() first");
		return;
	}

	float[] goals = float_view(&js, argc, args, 0);
	if (goals.len < 3)
	{
		*out = js.raise("three.nav.field(goals) wants at least one [x, y, z]");
		return;
	}

	float[] values = mem::new_array(float, self.nav.field_size());
	@pool()
	{
		sz count = goals.len / 3;
		Vec3[] points = mem::temp_array(Vec3, count);
		for (sz i = 0; i < count; i++) points[i] = { goals[i * 3], goals[i * 3 + 1], goals[i * 3 + 2] };

		if (!self.nav.solve(points, values))
		{
			mem::free(values);
			*out = qjs::int_value(-1);
			return;
		}
	};

	// A dead slot before a new one, so a script that makes and disposes a field
	// every few seconds does not walk the handle space upward for ever.
	foreach (i, &slot : self.nav_fields)
	{
		if (slot.live) continue;
		*slot = { .values = values, .live = true };
		*out = qjs::int_value((int)i);
		return;
	}

	self.nav_fields.push({ .values = values, .live = true });
	*out = qjs::int_value((int)(self.nav_fields.len() - 1));
}

<*
 The field a handle names, or null.

 Null covers a handle out of range, a disposed one, and — the case worth having
 the length check for — one that outlived the bake it was sized to.
*>
fn float[] JsRuntime.nav_field_of(&self, int handle)
{
	if (handle < 0 || (sz)handle >= self.nav_fields.len()) return {};
	NavFieldSlot slot = self.nav_fields[(sz)handle];
	if (!slot.live) return {};
	if (!self.nav.usable() || slot.values.len != self.nav.grid.cells.len) return {};
	return slot.values;
}

fn void js_nav_field_free(
	qjs::ContextRef ctx, qjs::Value* this_val, int argc, qjs::Value* args, void* opaque, qjs::Value* out
) @local
{
	JsRuntime* self = (JsRuntime*)opaque;
	qjs::Context js = qjs::wrap(ctx);

	int handle = arg_int(&js, argc, args, 0);
	if (handle < 0 || (sz)handle >= self.nav_fields.len()) { *out = qjs::bool_value(false); return; }

	NavFieldSlot* slot = &self.nav_fields[(sz)handle];
	if (!slot.live) { *out = qjs::bool_value(false); return; }
	if (slot.values.len > 0) mem::free(slot.values);
	*slot = {};
	*out = qjs::bool_value(true);
}

<*
 `navDirection(handle, x, y, z)` — the unit XZ direction that walks towards the
 goal, or `[0, 0, 0]` for nowhere to go.

 Allocates a three-element array, which measures at about 185 ns against 55 for a
 scalar. That is the right trade for *one* agent asking once a frame and the
 wrong one for a crowd — which is what `three.steer` is, and why it exists rather
 than this being called in a loop.
*>
fn void js_nav_direction(
	qjs::ContextRef ctx, qjs::Value* this_val, int argc, qjs::Value* args, void* opaque, qjs::Value* out
) @local
{
	JsRuntime* self = (JsRuntime*)opaque;
	qjs::Context js = qjs::wrap(ctx);

	float[] field = self.nav_field_of(arg_int(&js, argc, args, 0));
	Vec3 point = { arg_float(&js, argc, args, 1), arg_float(&js, argc, args, 2), arg_float(&js, argc, args, 3) };

	Vec3 direction = field.len == 0 ? (Vec3) { 0, 0, 0 } : self.nav.direction_at(field, point);
	*out = vec3_value(&js, direction);
}

<*
 `navCost(handle, x, y, z)` — how far the goal is along the ground.

 -1 for unreachable, which the prelude turns into `Infinity` before a script sees
 it. A cost is a distance and can never be negative, so the sentinel cannot be
 confused with an answer — and the conversion happens in JavaScript because C3
 has no infinity constant to send, and a large finite number would be
 indistinguishable from "far" at exactly the moment a caller has to decide
 whether to give up.
*>
fn void js_nav_cost(
	qjs::ContextRef ctx, qjs::Value* this_val, int argc, qjs::Value* args, void* opaque, qjs::Value* out
) @local
{
	JsRuntime* self = (JsRuntime*)opaque;
	qjs::Context js = qjs::wrap(ctx);

	float[] field = self.nav_field_of(arg_int(&js, argc, args, 0));
	if (field.len == 0) { *out = qjs::number_value(-1.0); return; }

	Vec3 point = { arg_float(&js, argc, args, 1), arg_float(&js, argc, args, 2), arg_float(&js, argc, args, 3) };
	float cost = self.nav.cost_at(field, point);
	*out = qjs::number_value(cost >= collision::VOXEL_UNREACHED ? -1.0 : (double)cost);
}

<*
 `navSample(handle, posBuffer, posByteOffset, posFloats, costBuffer,
 costByteOffset, costFloats, dirBuffer, dirByteOffset, dirFloats)` — the two
 verbs above, for a whole crowd, in one crossing.

 ## Why it is here and not written as a loop in the script

 The bare crossing that answers a number is 143 ns, and `field.cost(point)` — the
 same crossing through the `readVector` that allocates a three-element array and
 runs three `Number.isFinite` checks — is 455 ns. The ergonomics layer costs
 twice what the boundary does: a good trade for a verb called once a frame and a
 bad one for a verb called once per agent per frame, and both are this verb.
 `navDirection` is worse again, because it allocates its answer as well.

 Either output may be empty, so a caller asking only "how far is everyone from
 the goal" pays for no directions.

 ## -1 is unreachable, and it stays -1 here

 The single form's -1 becomes `Infinity` in the prelude before a script sees it.
 This one cannot: converting means a JavaScript pass over the array, which is
 precisely the loop being avoided. So the bulk contract is the host's own —
 `cost < 0` is unreachable — and the prelude says so rather than hiding it.

 A field handle that is dead, or a bake that has been replaced, fills the costs
 with -1 and the directions with zero rather than raising: "nowhere to go" is
 what every agent's answer would be anyway, and a crowd verb that throws leaves
 the caller with a half-written buffer and no way to tell how far it got.

 @return `How many agents were sampled.`
*>
fn void js_nav_sample(
	qjs::ContextRef ctx, qjs::Value* this_val, int argc, qjs::Value* args, void* opaque, qjs::Value* out
) @local
{
	JsRuntime* self = (JsRuntime*)opaque;
	qjs::Context js = qjs::wrap(ctx);

	float[] field = self.nav_field_of(arg_int(&js, argc, args, 0));
	float[] positions = float_view(&js, argc, args, 1);
	float[] costs = float_view(&js, argc, args, 4);
	float[] directions = float_view(&js, argc, args, 7);

	sz count = positions.len / 3;
	if (costs.len > 0 && costs.len < count) count = costs.len;
	if (directions.len > 0 && directions.len / 3 < count) count = directions.len / 3;
	if (count == 0) { *out = qjs::int_value(0); return; }

	for (sz i = 0; i < count; i++)
	{
		sz at = i * 3;
		Vec3 point = { positions[at], positions[at + 1], positions[at + 2] };

		if (costs.len > 0)
		{
			float cost = field.len == 0 ? collision::VOXEL_UNREACHED : self.nav.cost_at(field, point);
			costs[i] = cost >= collision::VOXEL_UNREACHED ? -1.0f : cost;
		}
		if (directions.len > 0)
		{
			Vec3 direction = field.len == 0 ? (Vec3) { 0, 0, 0 } : self.nav.direction_at(field, point);
			directions[at] = direction.x;
			directions[at + 1] = direction.y;
			directions[at + 2] = direction.z;
		}
	}
	*out = qjs::int_value((int)count);
}

<*
 `navPath(fromX, fromY, fromZ, toX, toY, toZ, buffer, byteOffset, floats)` — one
 agent, one route, shortened against the geometry.

 This solves a whole field and throws it away, which is the cost the two-verb
 split exists to make visible: a hundred agents heading for one door is a hundred
 solves for one answer, and `three.nav.field()` is that answer kept. A single
 wanderer replanning occasionally is what this is for.

 Dijkstra from the goal rather than A* from the start, for reuse:
 `collision::VoxelGrid.solve_field` is a written and tested chamfer transform
 with no priority queue in it, and it is fast for the one broad sheet a nav layer
 is. A* would be asymptotically better on a long route through a maze and would
 be a second pathfinder to keep correct.

 The Float32Array's capacity is in waypoints, three floats each. It answers with
 how many were written, including the start, and zero when there is no route.
*>
fn void js_nav_path(
	qjs::ContextRef ctx, qjs::Value* this_val, int argc, qjs::Value* args, void* opaque, qjs::Value* out
) @local
{
	JsRuntime* self = (JsRuntime*)opaque;
	qjs::Context js = qjs::wrap(ctx);

	if (!self.nav.usable())
	{
		*out = js.raise("three.nav.path() needs a baked mesh — call three.nav.bake() first");
		return;
	}

	Vec3 from = { arg_float(&js, argc, args, 0), arg_float(&js, argc, args, 1), arg_float(&js, argc, args, 2) };
	Vec3 to = { arg_float(&js, argc, args, 3), arg_float(&js, argc, args, 4), arg_float(&js, argc, args, 5) };

	float[] slots = float_view(&js, argc, args, 6);
	if (slots.len < 3) { *out = qjs::int_value(0); return; }

	@pool()
	{
		float[] field = mem::temp_array(float, self.nav.field_size());
		Vec3[1] goals = { to };
		if (!self.nav.solve(&goals, field)) { *out = qjs::int_value(0); return; }

		// The raw walk is one point per cell, so it can be as long as the reachable
		// set. Bounded by the caller's slice times a factor, because shortening is
		// what turns hundreds of cells into a handful of corners and a caller
		// asking for eight waypoints still needs the cells between them walked.
		sz raw_limit = math::min((sz)self.nav.field_size(), (sz)(slots.len / 3) * 64 + 64);
		Vec3[] raw = mem::temp_array(Vec3, raw_limit);
		uint count = self.nav.walk(field, from, raw);
		if (count == 0) { *out = qjs::int_value(0); return; }

		Vec3[] tight = mem::temp_array(Vec3, (sz)(slots.len / 3));
		uint kept = self.pass.scene.shorten_path(
			&self.pass.assets, &self.nav, raw[:(sz)count], count, tight, {});

		for (uint i = 0; i < kept; i++)
		{
			slots[i * 3] = tight[i].x;
			slots[i * 3 + 1] = tight[i].y;
			slots[i * 3 + 2] = tight[i].z;
		}
		*out = qjs::int_value((int)kept);
	};
}

<*
 `steer(posBuffer, posByteOffset, posFloats, outBuffer, outByteOffset, outFloats,
 fieldHandle, goalX, goalY, goalZ, maxSpeed, arriveRadius, separationRadius,
 separationWeight)`.

 The crowd verb, and the one place in this API where the whole point is that
 there is exactly one crossing however many agents there are. See
 `scene/steer.c3`.

 The last two arguments are the separation radius and its weight; a radius of
 zero turns it off, which is what a caller steering one agent means.
*>
fn void js_steer(
	qjs::ContextRef ctx, qjs::Value* this_val, int argc, qjs::Value* args, void* opaque, qjs::Value* out
) @local
{
	JsRuntime* self = (JsRuntime*)opaque;
	qjs::Context js = qjs::wrap(ctx);

	float[] positions = float_view(&js, argc, args, 0);
	float[] velocities = float_view(&js, argc, args, 3);
	if (positions.len < 3 || velocities.len < 3) { *out = qjs::int_value(0); return; }

	int handle = arg_int(&js, argc, args, 6);
	float[] field = self.nav_field_of(handle);

	SteerOptions options;
	options.goal = { arg_float(&js, argc, args, 7), arg_float(&js, argc, args, 8), arg_float(&js, argc, args, 9) };
	options.has_goal = handle < 0;
	options.max_speed = arg_float(&js, argc, args, 10);
	options.arrive_radius = arg_float(&js, argc, args, 11);
	options.separation_radius = arg_float(&js, argc, args, 12);
	options.separation_weight = arg_float(&js, argc, args, 13);

	steer_agents(positions, velocities, field.len == 0 ? null : &self.nav, field, options);
	*out = qjs::int_value((int)math::min(positions.len / 3, velocities.len / 3));
}
