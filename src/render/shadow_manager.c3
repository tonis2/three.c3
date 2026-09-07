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
	bool sample_static;
	uint scene_id;
	uint rejected;
	uint caster_signature;
	uint frame_slot;
	bool[SHADOW_MAX_VIEWS] scheduled;
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
	uint atlas_generation;
}

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

fn float MeshPass.shadow_importance(&self, uint index)
{
	if (index == 0) return float::max;
	Light light = self.lighting.lights[index];
	if (light.meta[2] == 0) return 1e20f;
	Vec3 position = { light.direction[0], light.direction[1], light.direction[2] };
	Vec3 distance = position - self.camera.eye();
	float score = light.direction[3] * light.direction[3] / math::max(distance.length_sq(), 1.0f);
	uint at = self.shadow_view_set.find({ shadow_identity(light, index), 0, shadow_kind(light) });
	// Keep a small preference for resident entries to avoid threshold churn.
	if (at != SHADOW_VIEW_NONE && self.shadow_view_set.views[at].static_valid) score *= 1.15f;
	return score;
}

fn void? MeshPass.prepare_shadow_manager(&self, Gpu* gpu, float aspect)
{
	self.shadows.live = false;
	self.point_shadows.live = false;
	ShadowViewSet* entries = &self.shadow_view_set;
	ShadowManager* manager = &self.shadow_manager;
	if (entries.budget.max_views == 0) entries.budget = DEFAULT_SHADOW_BUDGET;
	uint sun_size = self.shadows.enabled ? self.shadows.size : 0;
	uint local_size = self.point_shadows.enabled ? self.point_shadows.size : 0;
	uint view_limit = math::min(entries.budget.max_views, SHADOW_MAX_VIEWS);
	uint views = sun_size > 0 && view_limit > 0 ? 1 : 0;
	usz texels = views > 0 ? (usz)sun_size * sun_size : 0;
	for (uint i = 1; i < self.lighting.count && local_size > 0; i++)
	{
		uint parts = shadow_view_parts(shadow_kind(self.lighting.lights[i]));
		usz light_texels = (usz)local_size * local_size * parts;
		if (views + parts > view_limit || texels + light_texels > entries.budget.max_texels) continue;
		views += parts;
		texels += light_texels;
	}
	if (views == 0) return;
	uint requested_sun = sun_size;
	uint requested_local = local_size;
	bool want_static = self.scene.static_nodes > 0;
	bool reuse = manager.atlas.image != null && manager.request_sun == requested_sun
		&& manager.request_local == requested_local && manager.request_views == views
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
	uint selected_count = 0;
	uint parts_used = 0;
	for (uint ranked = 0; ranked < self.lighting.count; ranked++)
	{
		uint i = order[ranked];
		Light* light = &self.lighting.lights[i];
		light.meta[1] = SHADOW_VIEW_NONE;
		bool enabled = i == 0 ? self.shadows.live : self.point_shadows.live;
		if (!enabled) continue;
		uint parts = shadow_view_parts(shadow_kind(*light));
		if (parts_used + parts > entries.budget.max_views) { manager.rejected++; continue; }
		selected[selected_count++] = i; parts_used += parts;
		entries.want_light(shadow_identity(*light, i), shadow_kind(*light));
	}
	for (uint s = 0; s < selected_count; s++)
	{
		uint i = selected[s]; Light light = self.lighting.lights[i];
		uint size = i == 0 ? self.shadows.created : self.point_shadows.created;
		entries.admit_light(shadow_identity(light, i), shadow_kind(light), size);
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
				1.0f / tile.size, self.point_shadows.bias, 0, self.point_shadows.intensity };
			manager.light_indices[at] = i; manager.gpu_indices[at] = count;
			packed[count++] = { view.view_projection, view.atlas, view.params };
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
	manager.updates = 0; manager.update_texels = 0; manager.deferred = 0;
	ShadowGpuView* uploaded = self.shadow_view_buffers[manager.frame_slot].buffer != null
		? (ShadowGpuView*)self.shadow_view_buffers[manager.frame_slot].data() : null;
	for (uint at = 0; at < entries.count; at++) manager.scheduled[at] = false;
	for (uint packed = 0; packed < entries.active; packed++)
	{
		for (uint at = 0; at < entries.count; at++)
		{
			ShadowView* view = &entries.views[at];
			if (!view.live || manager.gpu_indices[at] != packed) continue;
			if (manager.plan == SHADOW_PLAN_FULL)
			{
				view.static_valid = false;
				view.live_valid = false;
			}
			uint passes = manager.plan == SHADOW_PLAN_FULL ? 1u : (view.static_valid ? 0u : 1u);
			if (manager.plan == SHADOW_PLAN_COMBINED) passes++;
			usz texels = (usz)view.size * view.size * passes;
			bool fits = passes == 0 || (manager.updates < entries.budget.max_updates
				&& manager.update_texels + texels <= entries.budget.max_update_texels);
			if (!fits)
			{
				// Keep the last complete static-plus-dynamic tile while another view
				// consumes the budget. A view with no complete live depth stays off.
				if (uploaded != null && !(manager.plan == SHADOW_PLAN_COMBINED && view.live_valid))
				{
					uploaded[packed].params[3] = 0;
				}
				manager.deferred++;
				continue;
			}
			manager.scheduled[at] = true;
			if (passes > 0) manager.updates++;
			manager.update_texels += texels;
		}
	}
}

fn void MeshPass.record_shadow_manager(&self, vk::CommandBuffer cmd)
{
	self.shadows.draws = 0; self.shadows.static_draws = 0;
	self.point_shadows.draws = 0; self.point_shadows.static_draws = 0;
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
	ShadowTile[SHADOW_MAX_VIEWS] copies;
	uint count = 0;
	for (uint at = 0; at < entries.count; at++) if (entries.views[at].live && manager.scheduled[at]) copies[count++] = manager.tiles[at];
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
		manager.atlas.begin_tile(cmd, manager.tiles[at], manager.plan == SHADOW_PLAN_FULL);
		uint i = manager.light_indices[at]; Light* light = &self.lighting.lights[i];
		uint draws = self.record_casters(cmd, manager.plan == SHADOW_PLAN_FULL ? CASTERS_ALL : CASTERS_DYNAMIC,
			view.view_projection, shadow_kind(*light) == ShadowViewKind.POINT ? light : null, view.key.part);
		if (i == 0) { self.shadows.draws += draws; }
		else { self.point_shadows.draws += draws; }
		vk::cmdEndRendering(cmd);
		view.live_valid = true;
	}
	manager.atlas.end_live(cmd);
}
