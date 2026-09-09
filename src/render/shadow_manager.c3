module three;

import vk;
import collision;
import std::math;
import std::math::matrix;
import std::io;

// Projection policy is separate from the one atlas and caster-rendering path.
struct ShadowManager
{
	ShadowAtlas atlas;
	ShadowTile[SHADOW_MAX_VIEWS] tiles;
	uint[SHADOW_MAX_VIEWS] light_indices;
	uint[SHADOW_MAX_VIEWS] gpu_indices;
	uint plan;
	uint previous_plan;
	bool plan_valid;
	bool sample_static;
	uint scene_id;
	uint rejected;
	uint caster_signature;
	uint frame_slot;
	bool[SHADOW_MAX_VIEWS] scheduled;
	bool[SHADOW_MAX_VIEWS] overlay;
	ulong[SHADOW_MAX_VIEWS] dynamic_signatures;
	ShadowRect[SHADOW_MAX_VIEWS] dynamic_rects;
	ShadowRect[SHADOW_MAX_VIEWS] update_rects;
	ShadowRect[SHADOW_MAX_VIEWS] cached_dynamic_rects;
	usz copied_texels;
	uint updates;
	usz update_texels;
	uint deferred;
	uint request_sun;
	uint request_local;
	uint request_views;
	uint resolved_sun;
	uint resolved_local;
	usz request_texels;
	usz request_bytes;
	bool request_static;
	usz request_local_texels;
	uint atlas_generation;
	// Which local lights hold shadows, by packed slot, and what that was decided
	// from — see `evaluate_shadow_policy`.
	bool[MAX_LIGHTS] policy_keep;
	uint policy_signature;
	uint policy_places;
	Vec3 policy_focus;
	double policy_ms;
	bool policy_valid;
	// The table the last frame uploaded, kept so a bake can read the atlas the
	// same way that frame did — the bake runs outside a frame and has no slot's
	// buffer to point at.
	ShadowGpuView[SHADOW_MAX_VIEWS] packed;
	uint packed_count;
}

// How far the camera's focus or a shadowed light moves before the residency
// ranking is worth redoing, and how long the last answer is held whatever moves.
const float SHADOW_POLICY_MOVE = 3.0f;
const double SHADOW_POLICY_HOLD_MS = 1000.0;

// A local directional light stands nowhere and lights everything, so it ranks
// above any placed light; `shadow.enabled = true` ranks above both and keeps its
// own order inside that tier.
const float SHADOW_POLICY_EVERYWHERE = 1e10f;
const float SHADOW_POLICY_EXPLICIT = 1e12f;

fn ShadowViewKind shadow_kind(Light light)
{
	switch (light.meta[2])
	{
		case 0: return ShadowViewKind.DIRECTIONAL;
		case 1: return ShadowViewKind.POINT;
		case 4: return ShadowViewKind.SPOT;
		default: return ShadowViewKind.AREA;
	}
}

fn uint shadow_identity(Light light, uint index) => index == 0 || light.meta[0] != 0
	? light.meta[0] : (0x80000000u | index);

<*
 The tile size one local light asks for, and 0 when it casts no shadow.

 `three.lights[i].shadow` overrides either half of `three.lights.shadow`: a
 light may turn its own shadow off while the rest keep theirs, or on while the
 registry default is off, and may name a size of its own.
*>
fn uint MeshPass.local_shadow_request(&self, uint index)
{
	if (index == 0 || index >= self.lighting.count) return 0;
	Light light = self.lighting.lights[index];
	uint mode = light_shadow_mode(light);
	if (mode == LIGHT_SHADOW_OFF) return 0;
	if (mode != LIGHT_SHADOW_ON && !self.point_shadows.enabled) return 0;
	uint size = light_shadow_size(light);
	return size > 0 ? size : self.point_shadows.size;
}

// What the atlas actually gives that light this frame, after the residency
// policy and after the atlas has been fitted to the budget.
fn uint MeshPass.local_shadow_tile(&self, uint index)
{
	if (!self.point_shadows.live || !self.shadow_manager.policy_keep[index]) return 0;
	uint request = self.local_shadow_request(index);
	return request == 0 ? 0 : math::min(request, self.point_shadows.created);
}

// The window the shaders put on a light's inverse-square falloff, as they use
// it — squared. `light_toward` in `surface.slang` and `shared_area_window`.
fn float shadow_light_window(float distance, float range)
{
	if (range <= 0) return 1.0f;
	float t = distance / range;
	float edge = math::clamp(1.0f - t * t * t * t, 0.0f, 1.0f);
	return edge * edge;
}

// What one light is worth per unit of colour, its luminance times its intensity.
fn float shadow_light_power(Light light) => light.color[3]
	* (0.2126f * light.color[0] + 0.7152f * light.color[1] + 0.0722f * light.color[2]);

<*
 How a local light ranks for a shadow when more of them want one than
 `three.lights.shadow.maxLocal` allows. Higher keeps its shadow.

 The rank is how much shadow the light can put on screen, not where it stands:
 its irradiance at the point the camera is looking at — `power * window(distance,
 range) / max(distance^2, 1)` with the shaders' own range window, so a light
 whose reach ends short of the shot scores nothing however near it is. An area
 light divides by pi, which is what `shared_area_shape` does to its power, so a
 disk of 600 W and a lantern of 3 W are one number. The colour is in the power,
 so a light dimmed to near-black gives its tiles up.

 A light whose script set `shadow.enabled = true` outranks every light that took
 the registry default, because that is the script saying which shadows it came
 for. Lights that all score nothing keep the scene's own order, which the
 importer leaves nearest the shot first.
*>
fn float MeshPass.shadow_policy_rank(&self, uint index)
{
	Light light = self.lighting.lights[index];
	float reach = light.direction[3];
	float rank = SHADOW_POLICY_EVERYWHERE;
	if (reach > 0)
	{
		Vec3 position = { light.direction[0], light.direction[1], light.direction[2] };
		Vec3 offset = position - self.camera.target;
		float square = offset.dot(offset);
		float lit = shadow_light_window(math::sqrt(square), reach);
		uint kind = light.meta[2];
		if (kind == 2 || kind == 3) lit /= (float)math::PI;
		rank = shadow_light_power(light) * lit / math::max(square, 1.0f);
	}
	return light_shadow_mode(light) == LIGHT_SHADOW_ON ? (rank + 1.0f) * SHADOW_POLICY_EXPLICIT : rank;
}

<*
 Which local lights keep shadows this frame.

 Not recomputed every frame, because a ranking that changes with the camera is
 a shadow that blinks: the answer is held until something a script did changes
 it, and otherwise until the camera's focus or a shadowed light has moved
 `SHADOW_POLICY_MOVE` metres *and* `SHADOW_POLICY_HOLD_MS` has passed. Anything
 a script writes — a light's own setting, `maxLocal`, the registry default —
 lands on the next frame rather than a second later.
*>
fn void MeshPass.evaluate_shadow_policy(&self)
{
	ShadowManager* manager = &self.shadow_manager;
	uint signature = 2166136261u;
	uint places = 2166136261u;
	for (uint i = 0; i < self.lighting.count; i++)
	{
		Light light = self.lighting.lights[i];
		uint request = self.local_shadow_request(i);
		// The range and the power are in the ranking, and both quantized — by
		// metres and by quarter-octaves — so animating one does not re-rank
		// every frame.
		uint reach = (uint)(int)math::floor(light.direction[3] / SHADOW_POLICY_MOVE);
		uint power = (uint)(int)math::floor(
			(float)math::log2((double)math::max(shadow_light_power(light), 1e-6f)) * 4.0f);
		uint[6] fields = { light.meta[0], light.meta[2], light.meta[3], request, reach, power };
		foreach (value : fields) signature = (signature ^ value) * 16777619u;
		if (request == 0) continue;
		for (uint k = 0; k < 3; k++)
		{
			int cell = (int)math::floor(light.direction[k] / SHADOW_POLICY_MOVE);
			places = (places ^ (uint)cell) * 16777619u;
		}
	}
	signature = (signature ^ self.lighting.count) * 16777619u;
	signature = (signature ^ self.point_shadows.max_local) * 16777619u;
	Vec3 focus = self.camera.target;
	bool changed = !manager.policy_valid || manager.policy_signature != signature;
	bool moved = (focus - manager.policy_focus).length() > SHADOW_POLICY_MOVE
		|| manager.policy_places != places;
	// The hold only binds a clock that is running: a headless frame that never
	// ticks one would otherwise never re-rank at all.
	double now = self.clock.last_wall_ms;
	bool held = now > manager.policy_ms && now - manager.policy_ms < SHADOW_POLICY_HOLD_MS;
	if (!changed && (!moved || held)) return;
	manager.policy_signature = signature;
	manager.policy_places = places;
	manager.policy_focus = focus;
	manager.policy_ms = now;
	manager.policy_valid = true;
	uint limit = self.point_shadows.max_local > 0 ? self.point_shadows.max_local : DEFAULT_LOCAL_SHADOWS;
	for (uint i = 0; i < MAX_LIGHTS; i++) manager.policy_keep[i] = false;
	for (uint kept = 0; kept < limit; kept++)
	{
		uint best = MAX_LIGHTS;
		float best_rank = -1.0f;
		for (uint i = 1; i < self.lighting.count; i++)
		{
			if (manager.policy_keep[i] || self.local_shadow_request(i) == 0) continue;
			float rank = self.shadow_policy_rank(i);
			if (rank > best_rank) { best_rank = rank; best = i; }
		}
		if (best == MAX_LIGHTS) break;
		manager.policy_keep[best] = true;
	}
}

fn float MeshPass.shadow_importance(&self, uint index)
{
	if (index == 0) return float::max;
	Light light = self.lighting.lights[index];
	float rank = self.shadow_policy_rank(index);
	uint at = self.shadow_view_set.find({ shadow_identity(light, index), 0, shadow_kind(light) });
	// Keep a small preference for resident entries to avoid threshold churn.
	if (at != SHADOW_VIEW_NONE && self.shadow_view_set.views[at].static_valid) rank *= 1.25f;
	// The frame's sort takes the largest first, and the brightest light ranks highest.
	return rank;
}

fn void? MeshPass.prepare_shadow_manager(&self, Gpu* gpu, float aspect)
{
	self.shadows.live = false;
	self.point_shadows.live = false;
	ShadowViewSet* entries = &self.shadow_view_set;
	ShadowManager* manager = &self.shadow_manager;
	manager.atlas.ensure_compare(gpu)!;
	if (entries.budget.max_views == 0) entries.budget = DEFAULT_SHADOW_BUDGET;
	self.evaluate_shadow_policy();
	uint sun_size = self.shadows.enabled ? self.shadows.size : 0;
	// The cap every resident local tile is clamped to: the largest one asked for.
	uint local_size = 0;
	for (uint i = 1; i < self.lighting.count; i++)
	{
		if (manager.policy_keep[i]) local_size = math::max(local_size, self.local_shadow_request(i));
	}
	uint view_limit = math::min(entries.budget.max_views, SHADOW_MAX_VIEWS);
	uint views = sun_size > 0 && view_limit > 0 ? 1 : 0;
	usz texels = views > 0 ? (usz)sun_size * sun_size : 0;
	usz local_texels = 0;
	for (uint i = 1; i < self.lighting.count && local_size > 0; i++)
	{
		if (!manager.policy_keep[i]) continue;
		uint request = math::min(self.local_shadow_request(i), local_size);
		if (request == 0) continue;
		uint parts = shadow_view_parts(shadow_kind(self.lighting.lights[i]));
		usz light_texels = (usz)request * request * parts;
		if (views + parts > view_limit || texels + light_texels > entries.budget.max_texels) continue;
		views += parts;
		texels += light_texels;
		local_texels += light_texels;
	}
	if (views == 0) return;
	uint requested_sun = sun_size;
	uint requested_local = local_size;
	bool want_static = self.scene.static_nodes > 0;
	bool reuse = manager.atlas.image != null && manager.request_sun == requested_sun
		&& manager.request_local == requested_local && manager.request_views == views
		&& manager.request_local_texels == local_texels
		&& manager.request_texels == entries.budget.max_texels
		&& manager.request_bytes == entries.budget.max_bytes && manager.request_static == want_static;
	uint width = manager.atlas.width;
	uint height = manager.atlas.height;
	if (reuse)
	{
		sun_size = manager.resolved_sun;
		local_size = manager.resolved_local;
	}
	else
	{
		width = math::max(sun_size, local_size);
		height = width;
		usz bytes_per_texel = self.scene.static_nodes > 0 ? 8 : 4;
		while ((usz)width * height < texels)
		{
			uint w = width;
			uint h = height;
			if (w <= h) { w *= 2; } else { h *= 2; }
			if (w > SHADOW_MAX_SIZE || h > SHADOW_MAX_SIZE
				|| (usz)w * h > entries.budget.max_texels
				|| (usz)w * h * bytes_per_texel > entries.budget.max_bytes) break;
			width = w; height = h;
		}
		while (((usz)width * height > entries.budget.max_texels
			|| (usz)width * height * bytes_per_texel > entries.budget.max_bytes)
			&& (width > SHADOW_MIN_SIZE || height > SHADOW_MIN_SIZE))
		{
			if (width >= height && width > SHADOW_MIN_SIZE) { width /= 2; }
			else if (height > SHADOW_MIN_SIZE) { height /= 2; }
			uint edge = math::min(width, height);
			sun_size = math::min(sun_size, edge);
			local_size = math::min(local_size, edge);
		}
		uint old_width = manager.atlas.width;
		uint old_height = manager.atlas.height;
		while (catch manager.atlas.ensure(gpu, width, height, want_static, entries.budget.max_bytes))
		{
			if (width <= SHADOW_MIN_SIZE && height <= SHADOW_MIN_SIZE)
			{
				manager.atlas.ensure(gpu, width, height, want_static, entries.budget.max_bytes)!;
			}
			if (width >= height && width > SHADOW_MIN_SIZE) { width /= 2; }
			else if (height > SHADOW_MIN_SIZE) { height /= 2; }
			sun_size = math::min(sun_size, math::min(width, height));
			local_size = math::min(local_size, math::min(width, height));
			uint local_views = views - (sun_size > 0 ? 1u : 0u);
			while (sun_size > local_size && (usz)sun_size * sun_size
				+ (usz)local_size * local_size * local_views > (usz)width * height)
			{
				sun_size /= 2;
			}
		}
		if (old_width != width || old_height != height || manager.atlas_generation != manager.atlas.generation)
		{
			for (uint i = 0; i < entries.count; i++)
			{
				entries.views[i].static_valid = false;
				entries.views[i].live_valid = false;
				manager.tiles[i] = { };
			}
		}
		manager.request_sun = requested_sun;
		manager.request_local = requested_local;
		manager.request_views = views;
		manager.request_local_texels = local_texels;
		manager.request_texels = entries.budget.max_texels;
		manager.request_bytes = entries.budget.max_bytes;
		manager.request_static = want_static;
		manager.resolved_sun = sun_size;
		manager.resolved_local = local_size;
		manager.atlas_generation = manager.atlas.generation;
	}
	if (manager.scene_id != self.scene.id)
	{
		for (uint i = 0; i < entries.count; i++)
		{
			entries.views[i].static_valid = false;
			entries.views[i].live_valid = false;
			manager.tiles[i] = { };
		}
		manager.scene_id = self.scene.id;
	}
	self.shadows.format = manager.atlas.format;
	self.shadows.build_pipeline(gpu)!;
	self.shadows.created = sun_size;
	self.point_shadows.created = local_size;
	self.point_shadows.live = local_size > 0 && views > (sun_size > 0 ? 1u : 0u);
	if (sun_size == 0) return;
	collision::Aabb3 bounds = self.scene.bounds(&self.assets);
	collision::Aabb3 focus;
	float focus_radius = 0;
	if (self.shadows.follow)
	{
		ViewSphere seen = self.camera.view_sphere(aspect, self.shadows.reach(self.camera.distance));
		Vec3 center = math::min(math::max(seen.center, bounds.min), bounds.max);
		Vec3 reach = { seen.radius, seen.radius, seen.radius };
		focus = { .min = center - reach, .max = center + reach };
		focus_radius = seen.radius;
	}
	self.shadows.fit(self.lighting.lights[0].direction, bounds, focus,
		stable: self.scene.static_nodes > 0, focus_radius: focus_radius);
	self.shadows.live = true;
}

fn bool shadow_tiles_overlap(ShadowTile a, ShadowTile b) => a.x < b.x + b.size
	&& b.x < a.x + a.size && a.y < b.y + b.size && b.y < a.y + a.size;

fn bool MeshPass.place_shadow_tile(&self, uint at)
{
	ShadowManager* manager = &self.shadow_manager;
	ShadowView* view = &self.shadow_view_set.views[at];
	if (manager.tiles[at].size == view.size) return true;
	for (uint y = 0; y + view.size <= manager.atlas.height; y += SHADOW_MIN_SIZE)
	{
		for (uint x = 0; x + view.size <= manager.atlas.width; x += SHADOW_MIN_SIZE)
		{
			ShadowTile tile = { x, y, view.size };
			bool free = true;
			for (uint j = 0; j < self.shadow_view_set.count; j++)
			{
				if (j != at && self.shadow_view_set.views[j].live && manager.tiles[j].size > 0
					&& shadow_tiles_overlap(tile, manager.tiles[j])) { free = false; break; }
			}
			if (!free) continue;
			manager.tiles[at] = tile;
			view.static_valid = false;
			view.live_valid = false;
			return true;
		}
	}
	return false;
}

fn Matrix4f MeshPass.shadow_projection(&self, Light light, uint index, uint part)
{
	ShadowViewKind kind = shadow_kind(light);
	if (kind == ShadowViewKind.POINT) return point_shadow_matrix(light, part);
	if (index == 0) return self.shadows.light_view_projection;
	if (kind == ShadowViewKind.DIRECTIONAL)
	{
		ShadowMap fit = self.shadows;
		fit.created = self.point_shadows.created;
		fit.fit(light.direction, self.scene.bounds(&self.assets));
		return fit.light_view_projection;
	}
	Vec3 eye = { light.direction[0], light.direction[1], light.direction[2] };
	Vec3 right = { light.area_right[0], light.area_right[1], light.area_right[2] };
	Vec3 up = { light.area_up[0], light.area_up[1], light.area_up[2] };
	Vec3 direction = kind == ShadowViewKind.SPOT ? right : -right.cross(up);
	if (direction.length_sq() < 1e-12f) direction = { 0, -1, 0 };
	direction = direction.normalize();
	if (kind == ShadowViewKind.SPOT) up = math::abs(direction.y) < 0.99f ? (Vec3){0,1,0} : (Vec3){1,0,0};
	float fov = (float)math::PI * (150.0f / 180.0f);
	if (kind == ShadowViewKind.SPOT)
	{
		fov = 2.0f * math::acos(math::clamp(light.area_right[3], -0.99f, 0.9999f));
	}
	float far_plane = math::max(light.direction[3], 0.1f);
	return matrix::perspective{float}(fov, 1.0f, 0.01f, far_plane)
		* matrix::look_at{float}(eye, eye + direction, up);
}

// Whether one contiguous instance range reaches this shadow view. The bounds
// match the conservative boxes used to build the frame's draw list.
fn bool MeshPass.shadow_range_reaches(&self, GpuMesh* mesh, Material* material, Bucket bucket,
	uint offset, uint count, Frustum* view, Light* point = null)
{
	if (count == 0) return false;
	// Morph weights can be combined beyond the imported union, and a vertex body
	// may do more than its declared culling margin. Keep both on the safe path.
	if (mesh.morph_targets > 0 || material.vertex.len > 0) return true;
	collision::Aabb3 local = mesh.bounds;
	if (mesh.has_skin)
	{
		Asset* owner = self.assets.slot(bucket.asset);
		if (owner != null && owner.pose_matrices > 0) local = owner.skinned_bounds;
	}
	if (bucket.node != NO_NODE)
	{
		SoftMesh* soft = self.scene.physics.soft_for(bucket.node);
		if (soft != null) local = soft.bounds;
	}
	Vec3 centre;
	float range2 = 0;
	if (point != null)
	{
		centre = { point.direction[0], point.direction[1], point.direction[2] };
		range2 = point.direction[3] * point.direction[3];
	}
	for (uint n = 0; n < count; n++)
	{
		Instance* copy = &self.shadow_instances[bucket.first + offset + n];
		collision::Aabb3 box = local.transform_matrix(copy.model);
		if (material.bounds > 0)
		{
			float margin = material.bounds;
			box = { .min = box.min - { margin, margin, margin },
				.max = box.max + { margin, margin, margin } };
		}
		if (point != null)
		{
			Vec3 nearest = math::min(math::max(centre, box.min), box.max);
			Vec3 delta = nearest - centre;
			if (delta.dot(delta) > range2) continue;
		}
		if (view.contains(box)) return true;
	}
	return false;
}

fn ShadowRect shadow_full_rect(ShadowTile tile) => { tile.x, tile.y, tile.size, tile.size };

fn ShadowRect shadow_rect_union(ShadowRect a, ShadowRect b)
{
	if (a.width == 0 || a.height == 0) return b;
	if (b.width == 0 || b.height == 0) return a;
	uint x = math::min(a.x, b.x);
	uint y = math::min(a.y, b.y);
	uint right = math::max(a.x + a.width, b.x + b.width);
	uint bottom = math::max(a.y + a.height, b.y + b.height);
	return { x, y, right - x, bottom - y };
}

// Conservative atlas rectangle of rigid copies. A corner behind the projection
// plane makes the clipped shape unbounded in ndc, so that case takes the tile.
fn bool MeshPass.shadow_range_rect(&self, GpuMesh* mesh, Material* material, Bucket bucket,
	uint offset, uint count, ShadowView* view, ShadowTile tile, ShadowRect* into)
{
	if (count == 0) return true;
	collision::Aabb3 local = mesh.bounds;
	for (uint n = 0; n < count; n++)
	{
		Instance* copy = &self.shadow_instances[bucket.first + offset + n];
		collision::Aabb3 box = local.transform_matrix(copy.model);
		if (material.bounds > 0)
		{
			float margin = material.bounds;
			box = { .min = box.min - { margin, margin, margin },
				.max = box.max + { margin, margin, margin } };
		}
		float min_x = 1.0f;
		float min_y = 1.0f;
		float max_x = -1.0f;
		float max_y = -1.0f;
		for (uint corner = 0; corner < 8; corner++)
		{
			Vec3 p = {
				(corner & 1) != 0 ? box.max.x : box.min.x,
				(corner & 2) != 0 ? box.max.y : box.min.y,
				(corner & 4) != 0 ? box.max.z : box.min.z,
			};
			float[<4>] clip = view.view_projection * (float[<4>]){ p.x, p.y, p.z, 1 };
			if (clip[3] <= 0) { *into = shadow_full_rect(tile); return false; }
			float x = clip[0] / clip[3];
			float y = clip[1] / clip[3];
			min_x = math::min(min_x, x); max_x = math::max(max_x, x);
			min_y = math::min(min_y, y); max_y = math::max(max_y, y);
		}
		min_x = math::clamp(min_x, -1.0f, 1.0f); max_x = math::clamp(max_x, -1.0f, 1.0f);
		min_y = math::clamp(min_y, -1.0f, 1.0f); max_y = math::clamp(max_y, -1.0f, 1.0f);
		// Include the widest area-light filter so its penumbra never escapes the
		// dynamic comparison gate or the atlas rectangle refreshed beneath it.
		const int FILTER_MARGIN = 7;
		int left = (int)math::floor((double)((min_x * 0.5f + 0.5f) * tile.size)) - FILTER_MARGIN;
		int right = (int)math::ceil((double)((max_x * 0.5f + 0.5f) * tile.size)) + FILTER_MARGIN;
		int top = (int)math::floor((double)((-0.5f * max_y + 0.5f) * tile.size)) - FILTER_MARGIN;
		int bottom = (int)math::ceil((double)((-0.5f * min_y + 0.5f) * tile.size)) + FILTER_MARGIN;
		left = math::clamp(left, 0, (int)tile.size); right = math::clamp(right, 0, (int)tile.size);
		top = math::clamp(top, 0, (int)tile.size); bottom = math::clamp(bottom, 0, (int)tile.size);
		if (right > left && bottom > top)
		{
			ShadowRect rect = { tile.x + (uint)left, tile.y + (uint)top,
				(uint)(right - left), (uint)(bottom - top) };
			*into = shadow_rect_union(*into, rect);
		}
	}
	return true;
}

// Hashes the rigid dynamic casters that reach a view. Skins, morphs, soft
// bodies and custom vertex programs are volatile because their final vertices
// do not live in Instance.
fn bool MeshPass.dynamic_shadow_state(&self, ShadowView* view, Light* light,
	bool all_casters, ShadowTile tile, ulong* signature, bool* deforming, ShadowRect* rect)
{
	Frustum frustum = frustum_of(view.view_projection);
	Light* point = view.key.kind == ShadowViewKind.POINT ? light : null;
	ulong hash = @hash_value(KEY_SEED, self.assets.revision);
	bool found = false;
	*deforming = false;
	*rect = { };
	foreach (i, bucket : self.scene.buckets)
	{
		uint at = i < self.draw_indices.len() ? self.draw_indices[i] : NOT_DRAWN;
		if (at == NOT_DRAWN) continue;
		GpuMesh* mesh = self.assets.mesh(bucket.asset, bucket.mesh);
		Material* material = self.material(bucket.material);
		if (mesh == null || material == null || !self.casts_shadow(material)) continue;
		uint tail = bucket.static_first + bucket.static_count;
		uint head_count = all_casters ? bucket.count : bucket.static_first;
		uint tail_count = all_casters ? 0 : bucket.count - tail;
		bool head = self.shadow_range_reaches(mesh, material, bucket, 0, head_count, &frustum, point);
		bool end = self.shadow_range_reaches(mesh, material, bucket, tail, tail_count, &frustum, point);
		if (!head && !end) continue;
		found = true;
		if (mesh.has_skin || mesh.morph_targets > 0 || bucket.node != NO_NODE || material.vertex.len > 0)
		{
			*deforming = true;
			*rect = shadow_full_rect(tile);
		}
		else
		{
			if (head) self.shadow_range_rect(mesh, material, bucket, 0, head_count, view, tile, rect);
			if (end) self.shadow_range_rect(mesh, material, bucket, tail, tail_count, view, tile, rect);
		}
		hash = @hash_value(hash, bucket.asset);
		hash = @hash_value(hash, bucket.mesh);
		hash = @hash_value(hash, bucket.material);
		// Opaque materials contribute no data to the depth shader. In particular,
		// animated shading uniforms must not invalidate an unchanged silhouette.
		if (material.alpha_test > 0)
		{
			hash = @hash_value(hash, material.alpha_test);
			hash = @hash_value(hash, material.texture);
			hash = @hash_value(hash, mesh.texture);
			hash = @hash_value(hash, material.opacity());
			hash = @hash_value(hash, mesh.base_color[3]);
			for (uint k = 0; k < 4; k++) hash = @hash_value(hash, material.uv_transform[k]);
			hash = @hash_value(hash, material.uv_variant_count);
			for (uint row = 0; row < material.uv_variant_count; row++)
			{
				hash = @hash_value(hash, material.uv_variants[row]);
			}
		}
		if (head) hash = hash_bytes(hash, &self.shadow_instances[bucket.first],
			(usz)(head_count * Instance::size));
		if (end) hash = hash_bytes(hash, &self.shadow_instances[bucket.first + tail],
			(usz)(tail_count * Instance::size));
	}
	*signature = hash;
	return found;
}

fn ulong? MeshPass.write_shadow_manager(&self, Gpu* gpu, uint slot)
{
	ShadowViewSet* entries = &self.shadow_view_set;
	ShadowManager* manager = &self.shadow_manager;
	manager.frame_slot = slot;
	uint[MAX_LIGHTS] order;
	float[MAX_LIGHTS] priorities;
	for (uint i = 0; i < self.lighting.count; i++)
	{
		order[i] = i; priorities[i] = self.shadow_importance(i);
	}
	for (uint i = 1; i < self.lighting.count; i++)
	{
		uint value = order[i];
		uint j = i;
		float priority = priorities[value];
		while (j > 0 && priorities[order[j - 1]] < priority)
		{
			order[j] = order[j - 1]; j--;
		}
		order[j] = value;
	}
	entries.reset(); manager.rejected = 0;
	uint[MAX_LIGHTS] selected;
	uint[MAX_LIGHTS] selected_size;
	uint selected_count = 0;
	uint parts_used = 0;
	for (uint ranked = 0; ranked < self.lighting.count; ranked++)
	{
		uint i = order[ranked];
		Light* light = &self.lighting.lights[i];
		light.meta[1] = SHADOW_VIEW_NONE;
		uint size = i == 0 ? (self.shadows.live ? self.shadows.created : 0) : self.local_shadow_tile(i);
		if (size == 0) continue;
		uint parts = shadow_view_parts(shadow_kind(*light));
		if (parts_used + parts > entries.budget.max_views) { manager.rejected++; continue; }
		selected_size[selected_count] = size;
		selected[selected_count++] = i; parts_used += parts;
		entries.want_light(shadow_identity(*light, i), shadow_kind(*light));
	}
	for (uint s = 0; s < selected_count; s++)
	{
		uint i = selected[s]; Light light = self.lighting.lights[i];
		entries.admit_light(shadow_identity(light, i), shadow_kind(light), selected_size[s]);
	}
	for (uint at = 0; at < entries.count; at++)
	{
		if (!entries.views[at].live || entries.views[at].size != manager.tiles[at].size)
		{
			manager.tiles[at] = { };
			entries.views[at].static_valid = false;
			entries.views[at].live_valid = false;
		}
	}
	ShadowGpuView[SHADOW_MAX_VIEWS] packed;
	uint count = 0;
	for (uint s = 0; s < selected_count; s++)
	{
		uint i = selected[s]; Light* light = &self.lighting.lights[i];
		ShadowViewKind kind = shadow_kind(*light);
		uint parts = shadow_view_parts(kind);
		uint first = count;
		bool placed = true;
		for (uint part = 0; part < parts; part++)
		{
			uint at = entries.find({ shadow_identity(*light, i), part, kind });
			if (at == SHADOW_VIEW_NONE || !entries.views[at].live || !self.place_shadow_tile(at))
			{ placed = false; break; }
			ShadowView* view = &entries.views[at];
			view.view_projection = self.shadow_projection(*light, i, part);
			uint signature = 2166136261u;
			for (uint k = 0; k < 16; k++) signature = (signature ^ bitcast(view.view_projection.m[k], uint)) * 16777619u;
			view.invalidate(signature, self.scene.static_revision);
			ShadowTile tile = manager.tiles[at];
			view.atlas = { (float)tile.size / manager.atlas.width, (float)tile.size / manager.atlas.height,
				(float)tile.x / manager.atlas.width, (float)tile.y / manager.atlas.height };
			view.params = i == 0 ? self.shadows.params() : (float[4]){
				1.0f / tile.size, self.point_shadows.bias, -LOCAL_SHADOW_NORMAL_OFFSET_TEXELS,
				self.point_shadows.intensity };
			manager.light_indices[at] = i; manager.gpu_indices[at] = count;
			packed[count++] = shadow_gpu_view(view.view_projection, view.atlas, view.params);
		}
		if (!placed)
		{
			count = first; manager.rejected++;
			for (uint part = 0; part < parts; part++)
			{
				uint at = entries.find({ shadow_identity(*light, i), part, kind });
				if (at != SHADOW_VIEW_NONE)
				{
					entries.views[at].live = false;
					entries.views[at].static_valid = false;
					entries.views[at].live_valid = false;
					manager.tiles[at] = { };
				}
			}
		}
		else { light.meta[1] = first; }
	}
	manager.packed_count = count;
	for (uint i = 0; i < count; i++) manager.packed[i] = packed[i];
	if (count == 0) return 0;
	sz bytes = count * ShadowGpuView::size;
	if (self.shadow_view_buffers[slot].buffer == null || self.shadow_view_buffers[slot].size < bytes)
	{
		vk::Memory buffer = gpu.create_dynamic(bytes)!;
		if (self.shadow_view_buffers[slot].buffer != null) self.shadow_view_buffers[slot].free();
		self.shadow_view_buffers[slot] = buffer;
	}
	self.shadow_view_buffers[slot].upload(&packed[0], bytes);
	return self.shadow_view_buffers[slot].address;
}

fn void MeshPass.plan_shadow_manager(&self, Gpu* gpu)
{
	ShadowManager* manager = &self.shadow_manager;
	ShadowViewSet* entries = &self.shadow_view_set;
	manager.plan = SHADOW_PLAN_FULL; manager.sample_static = false;
	uint statics = 0;
	uint movers = 0;
	uint cutouts = 0;
	bool changing = false;
	foreach (bucket : self.scene.buckets)
	{
		Material* material = self.material(bucket.material);
		GpuMesh* mesh = self.assets.mesh(bucket.asset, bucket.mesh);
		if (material == null || mesh == null || !self.casts_shadow(material)) continue;
		statics += bucket.static_count; movers += bucket.count - bucket.static_count;
		if (material.alpha_test > 0) cutouts++;
		if (bucket.static_count > 0 && (mesh.morph_targets > 0 || bucket.node != NO_NODE || material.vertex.len > 0)) changing = true;
	}
	if (cutouts > 0 && !self.shadows.cutout_ready && !self.shadows.cutout_refused)
	{
		if (catch self.shadows.build_cutout_pipeline(gpu)) self.shadows.cutout_refused = true;
	}
	if (statics > 0 && !changing && manager.atlas.image != null)
	{
		if (catch manager.atlas.ensure(gpu, manager.atlas.width, manager.atlas.height, true,
			entries.budget.max_bytes))
		{
			io::eprintn("three: shadow cache allocation failed; drawing all casters");
		}
		else { manager.plan = movers == 0 ? SHADOW_PLAN_STATIC : SHADOW_PLAN_COMBINED; }
	}
	manager.sample_static = manager.plan == SHADOW_PLAN_STATIC;
	if (!manager.plan_valid || manager.previous_plan != manager.plan)
	{
		for (uint at = 0; at < entries.count; at++)
		{
			entries.views[at].live_valid = false;
			entries.views[at].dynamic_valid = false;
			manager.cached_dynamic_rects[at] = { };
		}
		manager.previous_plan = manager.plan;
		manager.plan_valid = true;
	}
	uint signature = self.point_shadow_signature();
	if (manager.caster_signature != signature)
	{
		for (uint at = 0; at < self.shadow_view_set.count; at++)
		{
			self.shadow_view_set.views[at].static_valid = false;
			self.shadow_view_set.views[at].live_valid = false;
		}
		manager.caster_signature = signature;
	}
	self.shadows.plan = manager.plan; self.shadows.sample_static = manager.sample_static;
	self.point_shadows.plan = manager.plan; self.point_shadows.sample_static = manager.sample_static;
	manager.updates = 0; manager.update_texels = 0; manager.deferred = 0; manager.copied_texels = 0;
	ShadowGpuView* uploaded = self.shadow_view_buffers[manager.frame_slot].buffer != null
		? (ShadowGpuView*)self.shadow_view_buffers[manager.frame_slot].data() : null;
	for (uint at = 0; at < entries.count; at++)
	{
		manager.scheduled[at] = false;
		manager.overlay[at] = false;
		manager.dynamic_signatures[at] = 0;
		manager.dynamic_rects[at] = { };
		manager.update_rects[at] = { };
	}
	for (uint packed = 0; packed < entries.active; packed++)
	{
		for (uint at = 0; at < entries.count; at++)
		{
			ShadowView* view = &entries.views[at];
			if (!view.live || manager.gpu_indices[at] != packed) continue;
			bool static_work = manager.plan != SHADOW_PLAN_FULL && !view.static_valid;
			ulong dynamic_signature = 0;
			bool deforming = false;
			ShadowRect dynamic_rect;
			bool overlay = manager.plan != SHADOW_PLAN_STATIC
				&& self.dynamic_shadow_state(view, &self.lighting.lights[manager.light_indices[at]],
					manager.plan == SHADOW_PLAN_FULL, manager.tiles[at], &dynamic_signature, &deforming,
					&dynamic_rect);
			bool dynamic_changed = deforming || !view.dynamic_valid
				|| view.dynamic_signature != dynamic_signature;
			bool dynamic_work = overlay && dynamic_changed;
			bool copy = manager.plan == SHADOW_PLAN_COMBINED
				&& (static_work || dynamic_work || !view.live_valid || view.live_dynamic != overlay);
			manager.overlay[at] = overlay;
			manager.dynamic_signatures[at] = dynamic_signature;
			manager.dynamic_rects[at] = dynamic_rect;
			manager.update_rects[at] = static_work || !view.live_valid
				? shadow_full_rect(manager.tiles[at])
				: shadow_rect_union(manager.cached_dynamic_rects[at], dynamic_rect);
			if (manager.update_rects[at].width == 0 || manager.update_rects[at].height == 0)
			{
				manager.update_rects[at] = shadow_full_rect(manager.tiles[at]);
			}
			uint passes = manager.plan == SHADOW_PLAN_FULL ? (dynamic_changed || !view.live_valid ? 1u : 0u)
				: (static_work ? 1u : 0u) + (overlay && (static_work || dynamic_work || !view.live_valid) ? 1u : 0u);
			bool work = passes > 0 || copy;
			usz texels = (usz)view.size * view.size * passes;
			bool fits = !work || (manager.updates < entries.budget.max_updates
				&& manager.update_texels + texels <= entries.budget.max_update_texels);
			if (!fits)
			{
				// Keep the last complete static-plus-dynamic tile while another view
				// consumes the budget. A view with no complete live depth stays off.
				if (uploaded != null && !(manager.plan == SHADOW_PLAN_COMBINED && view.live_valid))
				{
					uploaded[packed].params[3] = 0;
				}
				else if (uploaded != null && manager.plan == SHADOW_PLAN_COMBINED
					&& view.static_valid && view.live_valid)
				{
					ShadowTile tile = manager.tiles[at];
					ShadowRect footprint = manager.cached_dynamic_rects[at];
					if (footprint.width > 0 && footprint.height > 0)
					{
						float inv = 1.0f / (float)tile.size;
						uploaded[packed].dynamic_rect = {
							(float)(footprint.x - tile.x) * inv,
							(float)(footprint.y - tile.y) * inv,
							(float)(footprint.x + footprint.width - tile.x) * inv,
							(float)(footprint.y + footprint.height - tile.y) * inv,
						};
					}
				}
				manager.deferred++;
				continue;
			}
			// A scheduled combined update completes before the colour pass reads
			// this frame block, so its freshly coherent pair may be used immediately.
			bool coherent = (view.static_valid && view.live_valid) || work;
			if (uploaded != null && overlay && manager.plan == SHADOW_PLAN_COMBINED && coherent)
			{
				ShadowTile tile = manager.tiles[at];
				ShadowRect footprint = shadow_rect_union(manager.cached_dynamic_rects[at], dynamic_rect);
				float inv = 1.0f / (float)tile.size;
				uploaded[packed].dynamic_rect = {
					(float)(footprint.x - tile.x) * inv,
					(float)(footprint.y - tile.y) * inv,
					(float)(footprint.x + footprint.width - tile.x) * inv,
					(float)(footprint.y + footprint.height - tile.y) * inv,
				};
			}
			manager.scheduled[at] = work;
			if (work) manager.updates++;
			manager.update_texels += texels;
		}
	}
}

fn void MeshPass.record_shadow_manager(&self, vk::CommandBuffer cmd)
{
	self.shadows.draws = 0; self.shadows.static_draws = 0;
	self.point_shadows.draws = 0; self.point_shadows.static_draws = 0;
	self.shadow_manager.atlas.record_blank(cmd);
	if (!self.prepared || (!self.shadows.live && !self.point_shadows.live)) return;
	ShadowManager* manager = &self.shadow_manager;
	ShadowViewSet* entries = &self.shadow_view_set;
	bool begun = false;
	if (manager.plan != SHADOW_PLAN_FULL)
	{
		for (uint at = 0; at < entries.count; at++)
		{
			ShadowView* view = &entries.views[at];
			if (!view.live || view.static_valid || !manager.scheduled[at]) continue;
			if (!begun) { manager.atlas.begin_static(cmd, false); begun = true; }
			manager.atlas.begin_tile(cmd, manager.tiles[at], true);
			uint i = manager.light_indices[at];
			Light* light = &self.lighting.lights[i];
			uint draws = self.record_casters(cmd, CASTERS_STATIC, view.view_projection,
				shadow_kind(*light) == ShadowViewKind.POINT ? light : null, view.key.part);
			if (i == 0) { self.shadows.static_draws += draws; }
			else { self.point_shadows.static_draws += draws; }
			vk::cmdEndRendering(cmd); view.static_valid = true;
			if (i == 0) self.shadows.mark_static_built(self.scene.static_revision);
		}
		if (!begun && !manager.atlas.static_initialized)
		{
			manager.atlas.begin_static(cmd, false); begun = true;
		}
		if (begun) manager.atlas.end_static(cmd);
	}
	if (manager.plan == SHADOW_PLAN_STATIC) return;
	ShadowRect[SHADOW_MAX_VIEWS] copies;
	uint count = 0;
	for (uint at = 0; at < entries.count; at++)
	{
		if (!entries.views[at].live || !manager.scheduled[at]) continue;
		copies[count++] = manager.update_rects[at];
		if (manager.plan == SHADOW_PLAN_COMBINED)
		{
			manager.copied_texels += (usz)manager.update_rects[at].width * manager.update_rects[at].height;
		}
	}
	if (count == 0)
	{
		if (!manager.atlas.initialized) { manager.atlas.begin_live(cmd, false); manager.atlas.end_live(cmd); }
		return;
	}
	if (manager.plan == SHADOW_PLAN_COMBINED) { manager.atlas.copy_static(cmd, copies[:count]); }
	else { manager.atlas.begin_live(cmd, false); }
	for (uint at = 0; at < entries.count; at++)
	{
		ShadowView* view = &entries.views[at];
		if (!view.live || !manager.scheduled[at]) continue;
		if (manager.plan == SHADOW_PLAN_COMBINED && !manager.overlay[at])
		{
			view.live_valid = true;
			view.live_dynamic = false;
			view.dynamic_valid = true;
			view.dynamic_signature = manager.dynamic_signatures[at];
			manager.cached_dynamic_rects[at] = manager.dynamic_rects[at];
			continue;
		}
		manager.atlas.begin_tile_rect(cmd, manager.tiles[at], manager.update_rects[at], manager.plan == SHADOW_PLAN_FULL);
		uint i = manager.light_indices[at]; Light* light = &self.lighting.lights[i];
		uint draws = self.record_casters(cmd, manager.plan == SHADOW_PLAN_FULL ? CASTERS_ALL : CASTERS_DYNAMIC,
			view.view_projection, shadow_kind(*light) == ShadowViewKind.POINT ? light : null, view.key.part);
		if (i == 0) { self.shadows.draws += draws; }
		else { self.point_shadows.draws += draws; }
		vk::cmdEndRendering(cmd);
		view.live_valid = true;
		view.live_dynamic = manager.plan == SHADOW_PLAN_COMBINED;
		if (manager.plan != SHADOW_PLAN_STATIC)
		{
			view.dynamic_valid = true;
			view.dynamic_signature = manager.dynamic_signatures[at];
			if (manager.plan == SHADOW_PLAN_COMBINED)
			{
				manager.cached_dynamic_rects[at] = manager.dynamic_rects[at];
			}
		}
	}
	manager.atlas.end_live(cmd);
}
