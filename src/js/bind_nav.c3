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
import fastjs::js;

fn void? JsRuntime.bind_nav_verbs(&self, js::Value host)
{
	// Every one of these takes the scene id first. A bake belongs to a scene — it
	// is voxelized out of that scene's triangles — and a field handle indexes that
	// scene's own list, so a verb that assumed the active one would solve the wrong
	// level's paths the moment a script baked ahead of a transition.
	self.js.@bind(host, "navBake", &js_nav_bake, self)!;
	self.js.@bind(host, "navLoad", &js_nav_load, self)!;
	self.js.@bind(host, "navStats", &js_nav_stats, self)!;
	self.js.@bind(host, "navClear", &js_nav_clear, self)!;
	self.js.@bind(host, "navField", &js_nav_field, self)!;
	self.js.@bind(host, "navFieldFree", &js_nav_field_free, self)!;
	self.js.@bind(host, "navDirection", &js_nav_direction, self)!;
	self.js.@bind(host, "navCost", &js_nav_cost, self)!;
	self.js.@bind(host, "navSample", &js_nav_sample, self)!;
	self.js.@bind(host, "navPath", &js_nav_path, self)!;
	self.js.@bind(host, "navPaths", &js_nav_paths, self)!;
	self.js.@bind(host, "steer", &js_steer, self)!;
}

<*
 The scene a `scene._sid` names.

 @return? js::THREW
*>
fn Scene*? nav_scene(JsRuntime* self, uint id) @local
{
	Scene* found = self.pass == null ? null : self.pass.scene_by_id(id);
	if (found == null) return self.js.fail("that Scene was disposed — its objects, its bodies and its nav bake are gone")~;
	return found;
}

<*
 `navLoad(sceneId, assetIndex, assetGeneration, profile)`: replace the bake with a
 profile embedded in a loaded glTF. An empty name prefers "default", then the
 first. Answers like `navStats`, or null when the asset has no profiles.

 @return? js::THREW
*>
fn js::Value? js_nav_load(JsRuntime* self, uint scene_id, uint asset_index, uint asset_generation, String wanted)
{
	Scene* scene = nav_scene(self, scene_id)!;
	AssetId id = { .index = asset_index, .generation = asset_generation };
	Asset* loaded = self.pass.assets.slot(id);
	if (loaded == null)
	{
		return self.js.fail("that asset is no longer loaded — three.unloadUnused() or scene.unload() freed it, "
			"and loading the file again gives a fresh handle")~;
	}
	if (loaded.nav_profiles.len() == 0) return js::NULL;

	AssetNavigationProfile* profile = null;
	if (wanted.len == 0)
	{
		foreach (&candidate : loaded.nav_profiles) if (candidate.name == "default") { profile = candidate; break; }
		if (profile == null) profile = &loaded.nav_profiles[0];
	}
	else
	{
		foreach (&candidate : loaded.nav_profiles) if (candidate.name == wanted) { profile = candidate; break; }
	}
	if (profile == null) return self.js.fail("that asset has no navigation profile named '%s'", wanted)~;
	if (!scene.load_nav(profile)) return js::NULL;
	return nav_stats_value(self, scene);
}

<*
 `navBake(sceneId, cell, radius, height, slope, stepHeight, hasBounds, minX, minY,
 minZ, maxX, maxY, maxZ)`.

 Answers with the same object `navStats` does, or `null` when the region held no
 standing room — a real answer and not an error: an empty scene, a scene of
 walls, or a slope limit nothing in it is under.

 @return? js::THREW
*>
fn js::Value? js_nav_bake(
	JsRuntime* self,
	uint scene_id,
	float cell,
	float radius,
	float height,
	float slope,
	float step_height,
	bool has_bounds,
	Vec3 min,
	Vec3 max
)
{
	Scene* scene = nav_scene(self, scene_id)!;

	NavSettings settings = default_nav_settings();
	if (cell > 0.0f) settings.cell = cell;
	settings.agent_radius = math::max(radius, 0.0f);
	settings.agent_height = math::max(height, 0.0f);
	settings.slope_limit = slope;
	settings.step_height = math::max(step_height, 0.0f);
	settings.has_bounds = has_bounds;
	if (has_bounds)
	{
		settings.bounds = { min, max };
		settings.bounds.fix();
	}

	// Everything over the old grid goes first — see `Scene.drop_nav`.
	scene.drop_nav();

	// This scene's triangles, which is the point: a level baked while it is off
	// screen is a level that costs nothing to switch to.
	if (!scene.bake_nav(&self.pass.assets, settings, &scene.nav)) return js::NULL;
	return nav_stats_value(self, scene);
}

<*
 What a bake produced and cost. `profile` and `sourceHash` are added only for a
 loaded profile that has them.
*>
struct NavStats
{
	float cell;
	float radius;
	float height;
	float step_height;
	float slope;
	// The counts and the time decide whether baking is a level-boundary operation
	// or a loading-screen one, for the caller's own level.
	double voxels;
	double solid;
	double floor;
	double walkable;
	// Whether the bake is *usable*: a total cannot tell a level an agent can cross
	// from the same level cut into islands — see `NavMesh.components`.
	double components;
	double largest;
	double bake_ms;
	// minX, minY, minZ, maxX, maxY, maxZ.
	float[<6>] bounds;
}

<*
 @return? js::THREW
*>
fn js::Value? nav_stats_value(JsRuntime* self, Scene* scene) @local
{
	NavMesh* nav = &scene.nav;
	if (!nav.usable()) return js::NULL;

	Vec3 lo = nav.grid.origin;
	Vec3 hi = lo + (Vec3) {
		(float)(nav.grid.nx - 1) * nav.grid.cell,
		(float)(nav.grid.ny - 1) * nav.grid.cell,
		(float)(nav.grid.nz - 1) * nav.grid.cell,
	};
	NavStats stats = {
		.cell = nav.settings.cell,
		.radius = nav.settings.agent_radius,
		.height = nav.settings.agent_height,
		.step_height = nav.settings.step_height,
		.slope = nav.settings.slope_limit,
		.voxels = (double)nav.voxels,
		.solid = (double)nav.solid_cells,
		.floor = (double)nav.floor_cells,
		.walkable = (double)nav.walkable_cells,
		.components = (double)nav.components,
		.largest = (double)nav.largest_component,
		.bake_ms = nav.bake_ms,
		.bounds = { lo.x, lo.y, lo.z, hi.x, hi.y, hi.z },
	};
	js::Value value = self.js.@object_of(stats)!;
	if (nav.profile_name.len > 0) self.js.set(value, "profile", self.js.string(nav.profile_name)!)!;
	if (nav.source_hash.len > 0) self.js.set(value, "sourceHash", self.js.string(nav.source_hash)!)!;
	return value;
}

<*
 `navStats(sceneId)`: the last bake, or null if there has not been one.

 @return? js::THREW
*>
fn js::Value? js_nav_stats(JsRuntime* self, uint scene_id)
{
	return nav_stats_value(self, nav_scene(self, scene_id)!);
}

<*
 `navClear(sceneId)`.

 @return? js::THREW
*>
fn void? js_nav_clear(JsRuntime* self, uint scene_id)
{
	nav_scene(self, scene_id)!.drop_nav();
}

<*
 `navField(sceneId, goals)`: solve towards a set of goals, a `Float32Array` of
 three floats each, and keep the answer.

 @return `A handle, or -1 when nothing was solved: no goal on a walkable cell.`
 @return? js::THREW
*>
fn int? js_nav_field(JsRuntime* self, uint scene_id, float[] goals)
{
	Scene* scene = nav_scene(self, scene_id)!;
	if (!scene.nav.usable()) return self.js.fail("three.nav.field() needs a baked mesh — call three.nav.bake() first")~;
	if (goals.len < 3) return self.js.fail("three.nav.field(goals) wants at least one [x, y, z]")~;

	float[] values = mem::new_array(float, scene.nav.field_size());
	@pool()
	{
		sz count      = goals.len / 3;
		Vec3[] points = mem::temp_array(Vec3, count);
		for (sz i = 0; i < count; i++) points[i] = { goals[i * 3], goals[i * 3 + 1], goals[i * 3 + 2] };

		if (!scene.nav.solve(points, values))
		{
			mem::free(values);
			return -1;
		}
	};

	// A dead slot before a new one, so a script that makes and disposes a field
	// every few seconds does not walk the handle space upward for ever.
	foreach (i, &slot : scene.nav_fields)
	{
		if (slot.live) continue;
		*slot = { .values = values, .live = true };
		return (int)i;
	}

	scene.nav_fields.push({ .values = values, .live = true });
	return (int)(scene.nav_fields.len() - 1);
}

<*
 The field a handle names, or null.

 Null covers a handle out of range, a disposed one, and — the case worth having
 the length check for — one that outlived the bake it was sized to.
*>
fn float[] Scene.nav_field_of(&self, int handle)
{
	if (handle < 0 || (sz)handle >= self.nav_fields.len()) return { };
	NavFieldSlot slot = self.nav_fields[(sz)handle];
	if (!slot.live) return { };
	if (!self.nav.usable() || slot.values.len != self.nav.grid.cells.len) return { };
	return slot.values;
}

<*
 `navFieldFree(sceneId, handle)`: false for a handle that was not live.

 @return? js::THREW
*>
fn bool? js_nav_field_free(JsRuntime* self, uint scene_id, int handle)
{
	Scene* scene = nav_scene(self, scene_id)!;
	if (handle < 0 || (sz)handle >= scene.nav_fields.len()) return false;

	NavFieldSlot* slot = &scene.nav_fields[(sz)handle];
	if (!slot.live) return false;
	if (slot.values.len > 0) mem::free(slot.values);
	*slot = { };
	return true;
}

<*
 `navDirection(sceneId, handle, x, y, z)`: the unit XZ direction that walks
 towards the goal, or `[0, 0, 0]` for nowhere to go. For one agent; a crowd is
 `steer`.

 @return? js::THREW
*>
fn Vec3? js_nav_direction(JsRuntime* self, uint scene_id, int handle, Vec3 point)
{
	Scene* scene  = nav_scene(self, scene_id)!;
	float[] field = scene.nav_field_of(handle);
	return field.len == 0 ? (Vec3) { 0, 0, 0 } : scene.nav.direction_at(field, point);
}

<*
 `navCost(sceneId, handle, x, y, z)`: how far the goal is along the ground.

 -1 for unreachable, which the prelude turns into `Infinity`. A cost is a distance
 and never negative, so the sentinel cannot be confused with an answer, and a
 large finite number would be indistinguishable from "far".

 @return? js::THREW
*>
fn double? js_nav_cost(JsRuntime* self, uint scene_id, int handle, Vec3 point)
{
	Scene* scene  = nav_scene(self, scene_id)!;
	float[] field = scene.nav_field_of(handle);
	if (field.len == 0) return -1.0;
	float cost = scene.nav.cost_at(field, point);
	return cost >= collision::VOXEL_UNREACHED ? -1.0 : (double)cost;
}

<*
 `navSample(sceneId, handle, positions, costs, directions)`: the two verbs above
 for a whole crowd, in one call. `costs` (one float per agent) or `directions`
 (three) may be undefined, so a caller asking only "how far is everyone" pays for
 no directions.

 ## -1 is unreachable, and it stays -1 here

 The single form's -1 becomes `Infinity` in the prelude. This one cannot:
 converting means a JavaScript pass over the array, which is the loop being
 avoided. So `cost < 0` is unreachable, and the prelude says so.

 A dead field handle, or a bake that has been replaced, fills the costs with -1
 and the directions with zero rather than raising: "nowhere to go" is what every
 agent's answer would be anyway, and a crowd verb that throws leaves the caller
 with a half-written buffer.

 @return `How many agents were sampled.`
 @return? js::THREW
*>
fn uint? js_nav_sample(JsRuntime* self, uint scene_id, int handle, float[] positions, float[] costs, float[] directions)
{
	Scene* scene  = nav_scene(self, scene_id)!;
	float[] field = scene.nav_field_of(handle);

	sz count = positions.len / 3;
	if (costs.len > 0 && costs.len < count) count = costs.len;
	if (directions.len > 0 && directions.len / 3 < count) count = directions.len / 3;

	for (sz i = 0; i < count; i++)
	{
		sz at      = i * 3;
		Vec3 point = { positions[at], positions[at + 1], positions[at + 2] };

		if (costs.len > 0)
		{
			float cost = field.len == 0 ? collision::VOXEL_UNREACHED : scene.nav.cost_at(field, point);
			costs[i] = cost >= collision::VOXEL_UNREACHED ? -1.0f : cost;
		}
		if (directions.len > 0)
		{
			Vec3 direction = field.len == 0 ? (Vec3) { 0, 0, 0 } : scene.nav.direction_at(field, point);
			directions[at] = direction.x;
			directions[at + 1] = direction.y;
			directions[at + 2] = direction.z;
		}
	}
	return (uint)count;
}

<*
 `navPath(sceneId, fromX, fromY, fromZ, toX, toY, toZ, out)`: one agent, one
 route, shortened against the geometry, into the `Float32Array` `out` (three
 floats a waypoint).

 A* from the goal towards the start, through the same solver `three.nav.field()`
 uses: the search stops once the start is settled, so its cost is the cells
 between the two ends rather than the whole bake. Searching from the goal is what
 lets `walk` descend the result from the start.

 @return `How many waypoints were written, including the start; zero when there is no route.`
 @return? js::THREW
*>
fn uint? js_nav_path(JsRuntime* self, uint scene_id, Vec3 start, Vec3 to, float[] out)
{
	Scene* scene = nav_scene(self, scene_id)!;
	if (!scene.nav.usable()) return self.js.fail("three.nav.path() needs a baked mesh — call three.nav.bake() first")~;
	if (out.len < 3) return 0;

	Vec3[1] from = { start };
	@pool()
	{
		float[] field = mem::temp_array(float, scene.nav.field_size());
		Vec3[1] goals = { to };
		if (!scene.nav.solve(&goals, field, &from)) return 0;
		return scene.route_from(&self.pass.assets, field, from[0], out);
	};
}

<*
 `navPaths(sceneId, starts, toX, toY, toZ, out, counts, limit)`: a group, one
 goal, one search. The search from the goal runs until every start is settled,
 and each agent then walks and shortens its own route out of the same field.

 `out` holds `limit` waypoints per agent, agent `i` from waypoint `i * limit`;
 `counts` (an `Int32Array`) gets each agent's waypoint count, zero for no route.

 @return `How many agents have a route.`
 @return? js::THREW
*>
fn int? js_nav_paths(JsRuntime* self, uint scene_id, float[] starts, Vec3 to, float[] out, int[] counts, int limit)
{
	Scene* scene = nav_scene(self, scene_id)!;
	if (!scene.nav.usable()) return self.js.fail("three.nav.paths() needs a baked mesh — call three.nav.bake() first")~;

	sz agents = starts.len / 3;
	if (agents == 0 || limit < 1 || counts.len < agents || out.len < agents * (sz)limit * 3) return 0;
	counts[:agents] = 0;

	@pool()
	{
		Vec3[] from = mem::temp_array(Vec3, agents);
		for (sz i = 0; i < agents; i++) from[i] = { starts[i * 3], starts[i * 3 + 1], starts[i * 3 + 2] };

		float[] field = mem::temp_array(float, scene.nav.field_size());
		Vec3[1] goals = { to };
		if (!scene.nav.solve(&goals, field, from)) return 0;

		int routed = 0;
		for (sz i = 0; i < agents; i++)
		{
			sz base   = i * (sz)limit * 3;
			counts[i] = (int)scene.route_from(&self.pass.assets, field, from[i], out[base:(sz)limit * 3]);
			if (counts[i] > 0) routed++;
		}
		return routed;
	};
}

<*
 Walks a solved field down from one start and shortens what it walked into
 `slots`, three floats a waypoint.

 @return `How many waypoints were written, including the start; zero when the walk does not reach the goal or the shortened route does not fit.`
*>
fn uint Scene.route_from(&self, Assets* assets, float[] field, Vec3 from, float[] slots)
{
	@pool()
	{
		// The raw walk is one point per cell. It must reach the goal before a
		// shortened route is returned; output capacity only limits kept corners.
		Vec3[] raw   = mem::temp_array(Vec3, self.nav.field_size());
		int[] voxels = mem::temp_array(int, self.nav.field_size());
		uint count   = self.nav.walk(field, from, raw, voxels);
		if (count == 0) return 0;

		Vec3[] tight = mem::temp_array(Vec3, slots.len / 3);
		uint kept = self.shorten_path(assets, &self.nav, raw[:(sz)count], voxels[:(sz)count], count, tight, { });
		for (uint i = 0; i < kept; i++)
		{
			slots[i * 3] = tight[i].x;
			slots[i * 3 + 1] = tight[i].y;
			slots[i * 3 + 2] = tight[i].z;
		}
		return kept;
	};
}

<*
 `steer(sceneId, positions, velocities, fieldHandle, goalX, goalY, goalZ,
 maxSpeed, arriveRadius, separationRadius, separationWeight)`: fill `velocities`
 with a desired velocity per agent, in one call however many agents there are.
 See `scene/steer.c3`.

 A separation radius of zero turns separation off, which is what a caller
 steering one agent means.

 @return `How many agents were steered.`
 @return? js::THREW
*>
fn uint? js_steer(
	JsRuntime* self,
	uint scene_id,
	float[] positions,
	float[] velocities,
	int handle,
	Vec3 goal,
	float max_speed,
	float arrive_radius,
	float separation_radius,
	float separation_weight
)
{
	Scene* scene = nav_scene(self, scene_id)!;
	if (positions.len < 3 || velocities.len < 3) return 0;

	float[] field = scene.nav_field_of(handle);
	SteerOptions options = {
		.goal = goal,
		.has_goal = handle < 0,
		.max_speed = max_speed,
		.arrive_radius = arrive_radius,
		.separation_radius = separation_radius,
		.separation_weight = separation_weight,
	};
	steer_agents(positions, velocities, field.len == 0 ? null : &scene.nav, field, options);
	return (uint)math::min(positions.len / 3, velocities.len / 3);
}
