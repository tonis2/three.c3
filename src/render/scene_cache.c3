<*
 Tracks the screen-space part of a scene whose shaded colour and depth must be
 rebuilt. Rendering remains the authority: a dirty rectangle is cleared and the
 ordinary draw list is replayed through its scissor.
*>
module three;

import vk;
import std::collections::list;
import std::math;
import std::math::vector;
import std::math::matrix;
import collision;

struct SceneCacheItem
{
	ulong identity;
	ulong state;
	ulong projection_state;
	vk::Rect2D rect;
	collision::Aabb3 world_box;
	uint seen;
	bool occupied;
}

struct SceneCache
{
	List{SceneCacheItem} items;
	List{ulong} node_group_states;
	List{ulong} material_states;
	vk::Extent2D extent;
	vk::Rect2D dirty;
	ulong global_state;
	uint epoch;
	bool valid;
	bool full;
	ulong[SHADOW_MAX_VIEWS] static_shadow_keys;
	vk::Rect2D[SHADOW_MAX_VIEWS] static_shadow_rects;
	bool[SHADOW_MAX_VIEWS] static_shadow_valid;
}

fn void SceneCache.free(&self)
{
	self.items.free();
	self.node_group_states.free();
	self.material_states.free();
	*self = { };
}

fn void SceneCache.invalidate(&self)
{
	self.valid = false;
}

fn vk::Rect2D scene_cache_full(vk::Extent2D extent) => { .offset = { 0, 0 }, .extent = extent };

fn bool scene_cache_empty(vk::Rect2D rect) => rect.extent.width == 0 || rect.extent.height == 0;

fn bool scene_cache_same(vk::Rect2D a, vk::Rect2D b) =>
	a.offset.x == b.offset.x && a.offset.y == b.offset.y
	&& a.extent.width == b.extent.width && a.extent.height == b.extent.height;

fn bool scene_cache_overlaps(vk::Rect2D a, vk::Rect2D b) =>
	a.offset.x < b.offset.x + (int)b.extent.width
	&& b.offset.x < a.offset.x + (int)a.extent.width
	&& a.offset.y < b.offset.y + (int)b.extent.height
	&& b.offset.y < a.offset.y + (int)a.extent.height;

fn vk::Rect2D scene_cache_union(vk::Rect2D a, vk::Rect2D b)
{
	if (scene_cache_empty(a)) return b;
	if (scene_cache_empty(b)) return a;
	int left = a.offset.x < b.offset.x ? a.offset.x : b.offset.x;
	int top = a.offset.y < b.offset.y ? a.offset.y : b.offset.y;
	int ar = a.offset.x + (int)a.extent.width;
	int br = b.offset.x + (int)b.extent.width;
	int ab = a.offset.y + (int)a.extent.height;
	int bb = b.offset.y + (int)b.extent.height;
	int right = ar > br ? ar : br;
	int bottom = ab > bb ? ab : bb;
	return { .offset = { left, top }, .extent = { (uint)(right - left), (uint)(bottom - top) } };
}

fn vk::Rect2D scene_cache_clip(vk::Rect2D rect, vk::Extent2D extent)
{
	int left = rect.offset.x > 0 ? rect.offset.x : 0;
	int top = rect.offset.y > 0 ? rect.offset.y : 0;
	int right = rect.offset.x + (int)rect.extent.width;
	int bottom = rect.offset.y + (int)rect.extent.height;
	if (right > (int)extent.width) right = (int)extent.width;
	if (bottom > (int)extent.height) bottom = (int)extent.height;
	if (right <= left || bottom <= top) return { };
	return { .offset = { left, top }, .extent = { (uint)(right - left), (uint)(bottom - top) } };
}

<*
 Starts one comparison against the last shaded scene. `global_state` contains
 everything which can change pixels outside an object's projected bounds.
*>
fn void SceneCache.begin(&self, vk::Extent2D extent, ulong global_state)
{
	if (self.items.allocator == null) self.items.init(mem, 64);
	self.epoch++;
	if (self.epoch == 0)
	{
		foreach (&item : self.items) item.seen = 0;
		self.epoch = 1;
	}
	self.dirty = { };
	self.full = !self.valid || self.extent.width != extent.width || self.extent.height != extent.height
		|| self.global_state != global_state;
	self.extent = extent;
	self.global_state = global_state;
}

<*
 Adds one stable drawable. A changed copy contributes both its old and new
 rectangles, so moving, shrinking and leaving the frustum erase old pixels.
*>
fn bool SceneCache.projected(&self, ulong identity, ulong projection_state,
	vk::Rect2D* rect, collision::Aabb3* world_box)
{
	uint slot = (uint)identity;
	if (slot >= self.items.len()) return false;
	SceneCacheItem* item = &self.items[slot];
	if (!item.occupied || item.identity != identity || item.projection_state != projection_state) return false;
	*rect = item.rect;
	*world_box = item.world_box;
	return true;
}

fn void SceneCache.observe(&self, ulong identity, ulong state, vk::Rect2D rect,
	ulong projection_state = 0, collision::Aabb3 world_box = {})
{
	rect = scene_cache_clip(rect, self.extent);
	uint slot = (uint)identity;
	while (self.items.len() <= slot) self.items.push({ });
	SceneCacheItem* item = &self.items[slot];
	if (item.occupied && item.identity == identity)
	{
		item.seen = self.epoch;
		if (item.state != state || !scene_cache_same(item.rect, rect))
		{
			self.dirty = scene_cache_union(self.dirty, item.rect);
			self.dirty = scene_cache_union(self.dirty, rect);
			item.state = state;
			item.rect = rect;
		}
		item.projection_state = projection_state;
		item.world_box = world_box;
		return;
	}
	if (item.occupied) self.dirty = scene_cache_union(self.dirty, item.rect);
	*item = { .identity = identity, .state = state, .projection_state = projection_state,
		.rect = rect, .world_box = world_box,
		.seen = self.epoch, .occupied = true };
	self.dirty = scene_cache_union(self.dirty, rect);
}

// Includes a shadow receiver region or another change not owned by one object.
fn void SceneCache.touch(&self, vk::Rect2D rect)
{
	self.dirty = scene_cache_union(self.dirty, scene_cache_clip(rect, self.extent));
}

fn vk::Rect2D SceneCache.finish(&self)
{
	foreach (&item : self.items)
	{
		if (!item.occupied || item.seen == self.epoch) continue;
		self.dirty = scene_cache_union(self.dirty, item.rect);
		*item = { };
	}
	if (self.full) self.dirty = scene_cache_full(self.extent);
	self.valid = true;
	return self.dirty;
}

const uint[24] SCENE_CACHE_BOX_EDGES = {
	0,1, 2,3, 4,5, 6,7, 0,2, 1,3, 4,6, 5,7, 0,4, 1,5, 2,6, 3,7
};
const uint[24] SCENE_CACHE_BOX_FACES = {
	0,1,3,2, 4,6,7,5, 0,2,6,4, 1,5,7,3, 0,4,5,1, 2,3,7,6
};

fn float scene_cache_clip_plane(float[<4>] p, uint plane)
{
	switch (plane)
	{
		case 0: return p[0] + p[3];
		case 1: return p[3] - p[0];
		case 2: return p[1] + p[3];
		case 3: return p[3] - p[1];
		case 4: return p[2];
		default: return p[3] - p[2];
	}
}

// Clips one segment against Vulkan's homogeneous camera volume.
fn bool scene_cache_clip_segment(float[<4>]* a, float[<4>]* b)
{
	float first = 0;
	float last = 1;
	for (uint plane = 0; plane < 6; plane++)
	{
		float da = scene_cache_clip_plane(*a, plane);
		float db = scene_cache_clip_plane(*b, plane);
		if (da < 0 && db < 0) return false;
		if (da >= 0 && db >= 0) continue;
		float t = da / (da - db);
		if (da < 0) { first = math::max(first, t); }
		else { last = math::min(last, t); }
	}
	if (first > last) return false;
	float[<4>] start = *a;
	float[<4>] delta = *b - start;
	*a = start + delta * first;
	*b = start + delta * last;
	return true;
}

<*
 Projects a convex eight-corner box and clips its edges at the near and side
 planes. `false` means it is wholly off screen. A frustum enclosed by the box is
 conservatively returned as the full target.
*>
fn bool scene_cache_project_points(float[<4>][8] world, Matrix4f camera,
	vk::Extent2D extent, uint padding, vk::Rect2D* out)
{
	float[<4>][8] clip;
	for (uint i = 0; i < 8; i++) clip[i] = camera * world[i];
	for (uint plane = 0; plane < 6; plane++)
	{
		bool outside = true;
		for (uint i = 0; i < 8; i++) if (scene_cache_clip_plane(clip[i], plane) >= 0) { outside = false; break; }
		if (outside) return false;
	}
	float min_x = 1;
	float min_y = 1;
	float max_x = -1;
	float max_y = -1;
	bool found = false;
	for (uint edge = 0; edge < 12; edge++)
	{
		float[<4>] a = clip[SCENE_CACHE_BOX_EDGES[edge * 2]];
		float[<4>] b = clip[SCENE_CACHE_BOX_EDGES[edge * 2 + 1]];
		if (!scene_cache_clip_segment(&a, &b)) continue;
		float[<4>][2] ends = { a, b };
		for (uint end = 0; end < 2; end++)
		{
			float x = ends[end][0] / ends[end][3];
			float y = ends[end][1] / ends[end][3];
			min_x = math::min(min_x, x); max_x = math::max(max_x, x);
			min_y = math::min(min_y, y); max_y = math::max(max_y, y);
			found = true;
		}
	}
	if (!found) { *out = scene_cache_full(extent); return true; }
	int left = (int)math::floor((double)((min_x * 0.5f + 0.5f) * extent.width)) - (int)padding;
	int right = (int)math::ceil((double)((max_x * 0.5f + 0.5f) * extent.width)) + (int)padding;
	int top = (int)math::floor((double)((-max_y * 0.5f + 0.5f) * extent.height)) - (int)padding;
	int bottom = (int)math::ceil((double)((-min_y * 0.5f + 0.5f) * extent.height)) + (int)padding;
	*out = scene_cache_clip({ .offset = { left, top },
		.extent = { (uint)math::max(0, right - left), (uint)math::max(0, bottom - top) } }, extent);
	return !scene_cache_empty(*out);
}

fn bool scene_cache_project_box(collision::Aabb3 box, Matrix4f camera,
	vk::Extent2D extent, uint padding, vk::Rect2D* out)
{
	float[<4>][8] points;
	for (uint corner = 0; corner < 8; corner++)
	{
		points[corner] = {
			(corner & 1) != 0 ? box.max.x : box.min.x,
			(corner & 2) != 0 ? box.max.y : box.min.y,
			(corner & 4) != 0 ? box.max.z : box.min.z,
			1,
		};
	}
	bool found = scene_cache_project_points(points, camera, extent, padding, out);

	// Add the other half of a complete convex intersection: camera-frustum edges
	// piercing box faces. Box edges alone miss a large box wrapped around a narrow
	// view and can underestimate a near-plane crossing.
	Matrix4f inverse_camera = invert(camera);
	float[<4>][8] frustum;
	for (uint corner = 0; corner < 8; corner++)
	{
		float[<4>] p = inverse_camera * (float[<4>]) {
			(corner & 1) != 0 ? 1 : -1, (corner & 2) != 0 ? 1 : -1,
			(corner & 4) != 0 ? 1 : 0, 1 };
		frustum[corner] = p / p[3];
	}
	for (uint edge = 0; edge < 12; edge++)
	{
		float[<4>] a = frustum[SCENE_CACHE_BOX_EDGES[edge * 2]];
		float[<4>] b = frustum[SCENE_CACHE_BOX_EDGES[edge * 2 + 1]];
		float first = 0;
		float last = 1;
		for (uint axis = 0; axis < 3; axis++)
		{
			float d = b[axis] - a[axis];
			float lo = axis == 0 ? box.min.x : (axis == 1 ? box.min.y : box.min.z);
			float hi = axis == 0 ? box.max.x : (axis == 1 ? box.max.y : box.max.z);
			if (math::abs(d) < 1e-8f)
			{
				if (a[axis] < lo || a[axis] > hi) { first = 1; last = 0; break; }
				continue;
			}
			float t0 = (lo - a[axis]) / d;
			float t1 = (hi - a[axis]) / d;
			if (t0 > t1) { float swap = t0; t0 = t1; t1 = swap; }
			first = math::max(first, t0); last = math::min(last, t1);
		}
		if (first > last) continue;
		float[<4>] delta = b - a;
		float[<4>][2] ends = { a + delta * first, a + delta * last };
		for (uint end = 0; end < 2; end++)
		{
			float[<4>] p = camera * ends[end];
			float sx = (p[0] / p[3] * 0.5f + 0.5f) * extent.width;
			float sy = (-p[1] / p[3] * 0.5f + 0.5f) * extent.height;
			vk::Rect2D point = scene_cache_clip({ .offset = { (int)math::floor((double)sx) - (int)padding,
				(int)math::floor((double)sy) - (int)padding },
				.extent = { padding * 2 + 1, padding * 2 + 1 } }, extent);
			*out = found ? scene_cache_union(*out, point) : point;
			found = !scene_cache_empty(*out);
		}
	}
	return found;
}

<*
 Projects the changed texels of a shadow view through its complete depth range.
 This is the receiver region: it extends beyond the caster's own screen bounds.
*>
fn bool scene_cache_project_shadow(ShadowView* view, ShadowTile tile, ShadowRect changed,
	Matrix4f camera, vk::Extent2D extent, vk::Rect2D* out)
{
	if (changed.width == 0 || changed.height == 0 || tile.size == 0) return false;
	float u0 = (float)((int)changed.x - (int)tile.x) / (float)tile.size;
	float v0 = (float)((int)changed.y - (int)tile.y) / (float)tile.size;
	float u1 = (float)((int)(changed.x + changed.width) - (int)tile.x) / (float)tile.size;
	float v1 = (float)((int)(changed.y + changed.height) - (int)tile.y) / (float)tile.size;
	Matrix4f inverse_light = invert(view.view_projection);
	float[<4>][8] world;
	for (uint corner = 0; corner < 8; corner++)
	{
		float u = (corner & 1) != 0 ? u1 : u0;
		float v = (corner & 2) != 0 ? v1 : v0;
		float z = (corner & 4) != 0 ? 1 : 0;
		float[<4>] p = inverse_light * (float[<4>]) { u * 2 - 1, 1 - v * 2, z, 1 };
		world[corner] = p / p[3];
	}
	bool found = scene_cache_project_points(world, camera, extent, 3, out);

	// The intersection of two convex volumes also has vertices made by an edge of
	// the camera frustum piercing a face of the shadow prism. Add those edges; the
	// prism edges above alone can underestimate or miss that shape entirely.
	Matrix4f inverse_camera = invert(camera);
	float[<4>][8] camera_world;
	for (uint corner = 0; corner < 8; corner++)
	{
		float[<4>] p = inverse_camera * (float[<4>]) {
			(corner & 1) != 0 ? 1 : -1,
			(corner & 2) != 0 ? 1 : -1,
			(corner & 4) != 0 ? 1 : 0,
			1,
		};
		camera_world[corner] = p / p[3];
	}
	float x0 = u0 * 2 - 1;
	float x1 = u1 * 2 - 1;
	float y0 = 1 - v1 * 2;
	float y1 = 1 - v0 * 2;
	for (uint edge = 0; edge < 12; edge++)
	{
		float[<4>] wa = camera_world[SCENE_CACHE_BOX_EDGES[edge * 2]];
		float[<4>] wb = camera_world[SCENE_CACHE_BOX_EDGES[edge * 2 + 1]];
		float[<4>] la = view.view_projection * wa;
		float[<4>] lb = view.view_projection * wb;
		float first = 0;
		float last = 1;
		for (uint plane = 0; plane < 6; plane++)
		{
			float da;
			float db;
			switch (plane)
			{
				case 0: da = la[0] - x0 * la[3]; db = lb[0] - x0 * lb[3];
				case 1: da = x1 * la[3] - la[0]; db = x1 * lb[3] - lb[0];
				case 2: da = la[1] - y0 * la[3]; db = lb[1] - y0 * lb[3];
				case 3: da = y1 * la[3] - la[1]; db = y1 * lb[3] - lb[1];
				case 4: da = la[2]; db = lb[2];
				default: da = la[3] - la[2]; db = lb[3] - lb[2];
			}
			if (da < 0 && db < 0) { first = 1; last = 0; break; }
			if (da >= 0 && db >= 0) continue;
			float t = da / (da - db);
			if (da < 0) { first = math::max(first, t); }
			else { last = math::min(last, t); }
		}
		if (first > last) continue;
		float[<4>] delta = wb - wa;
		float[<4>][2] ends = { wa + delta * first, wa + delta * last };
		for (uint end = 0; end < 2; end++)
		{
			float[<4>] p = camera * ends[end];
			float sx = (p[0] / p[3] * 0.5f + 0.5f) * extent.width;
			float sy = (-p[1] / p[3] * 0.5f + 0.5f) * extent.height;
			vk::Rect2D point = scene_cache_clip({ .offset = { (int)math::floor((double)sx) - 3,
				(int)math::floor((double)sy) - 3 }, .extent = { 7, 7 } }, extent);
			*out = found ? scene_cache_union(*out, point) : point;
			found = !scene_cache_empty(*out);
		}
	}
	return found;
}

fn bool scene_cache_shadow_reaches_box(ShadowView* view, ShadowTile tile,
	ShadowRect changed, collision::Aabb3 box)
{
	float min_x = 1;
	float min_y = 1;
	float max_x = -1;
	float max_y = -1;
	for (uint corner = 0; corner < 8; corner++)
	{
		float[<4>] p = view.view_projection * (float[<4>]) {
			(corner & 1) != 0 ? box.max.x : box.min.x,
			(corner & 2) != 0 ? box.max.y : box.min.y,
			(corner & 4) != 0 ? box.max.z : box.min.z, 1 };
		if (p[3] <= 0) return true;
		float x = p[0] / p[3];
		float y = p[1] / p[3];
		min_x = math::min(min_x, x); max_x = math::max(max_x, x);
		min_y = math::min(min_y, y); max_y = math::max(max_y, y);
	}
	int left = (int)tile.x + (int)math::floor((double)((min_x * 0.5f + 0.5f) * tile.size)) - 3;
	int right = (int)tile.x + (int)math::ceil((double)((max_x * 0.5f + 0.5f) * tile.size)) + 3;
	int top = (int)tile.y + (int)math::floor((double)((-max_y * 0.5f + 0.5f) * tile.size)) - 3;
	int bottom = (int)tile.y + (int)math::ceil((double)((-min_y * 0.5f + 0.5f) * tile.size)) + 3;
	int changed_right = (int)(changed.x + changed.width);
	int changed_bottom = (int)(changed.y + changed.height);
	return right > (int)changed.x && left < changed_right
		&& bottom > (int)changed.y && top < changed_bottom;
}

fn bool scene_cache_clip_world_box(float[<4>]* a, float[<4>]* b, collision::Aabb3 box)
{
	float first = 0;
	float last = 1;
	for (uint axis = 0; axis < 3; axis++)
	{
		float d = (*b)[axis] - (*a)[axis];
		float lo = axis == 0 ? box.min.x : (axis == 1 ? box.min.y : box.min.z);
		float hi = axis == 0 ? box.max.x : (axis == 1 ? box.max.y : box.max.z);
		if (math::abs(d) < 1e-8f)
		{
			if ((*a)[axis] < lo || (*a)[axis] > hi) return false;
			continue;
		}
		float t0 = (lo - (*a)[axis]) / d;
		float t1 = (hi - (*a)[axis]) / d;
		if (t0 > t1) { float swap = t0; t0 = t1; t1 = swap; }
		first = math::max(first, t0);
		last = math::min(last, t1);
	}
	if (first > last) return false;
	float[<4>] start = *a;
	float[<4>] delta = *b - start;
	*a = start + delta * first;
	*b = start + delta * last;
	return true;
}

fn bool scene_cache_clip_shadow_prism(float[<4>]* a, float[<4>]* b, Matrix4f light,
	float x0, float x1, float y0, float y1)
{
	float[<4>] ca = light * *a;
	float[<4>] cb = light * *b;
	float first = 0;
	float last = 1;
	for (uint plane = 0; plane < 6; plane++)
	{
		float da;
		float db;
		switch (plane)
		{
			case 0: da = ca[0] - x0 * ca[3]; db = cb[0] - x0 * cb[3];
			case 1: da = x1 * ca[3] - ca[0]; db = x1 * cb[3] - cb[0];
			case 2: da = ca[1] - y0 * ca[3]; db = cb[1] - y0 * cb[3];
			case 3: da = y1 * ca[3] - ca[1]; db = y1 * cb[3] - cb[1];
			case 4: da = ca[2]; db = cb[2];
			default: da = ca[3] - ca[2]; db = cb[3] - cb[2];
		}
		if (da < 0 && db < 0) return false;
		if (da >= 0 && db >= 0) continue;
		float t = da / (da - db);
		if (da < 0) { first = math::max(first, t); }
		else { last = math::min(last, t); }
	}
	if (first > last) return false;
	float[<4>] start = *a;
	float[<4>] delta = *b - start;
	*a = start + delta * first;
	*b = start + delta * last;
	return true;
}

fn void scene_cache_add_screen_point(vk::Rect2D* rect, bool* found, float[<4>] world,
	Matrix4f camera, vk::Extent2D extent)
{
	float[<4>] p = camera * world;
	if (p[3] <= 0) return;
	float sx = (p[0] / p[3] * 0.5f + 0.5f) * extent.width;
	float sy = (-p[1] / p[3] * 0.5f + 0.5f) * extent.height;
	vk::Rect2D point = scene_cache_clip({ .offset = { (int)math::floor((double)sx) - 3,
		(int)math::floor((double)sy) - 3 }, .extent = { 7, 7 } }, extent);
	*rect = *found ? scene_cache_union(*rect, point) : point;
	*found = !scene_cache_empty(*rect);
}

fn void scene_cache_add_segment(vk::Rect2D* rect, bool* found, float[<4>] a,
	float[<4>] b, Matrix4f camera, vk::Extent2D extent)
{
	float[<4>] ca = camera * a;
	float[<4>] cb = camera * b;
	if (!scene_cache_clip_segment(&ca, &cb)) return;
	float[<4>][2] ends = { ca, cb };
	for (uint end = 0; end < 2; end++)
	{
		float sx = (ends[end][0] / ends[end][3] * 0.5f + 0.5f) * extent.width;
		float sy = (-ends[end][1] / ends[end][3] * 0.5f + 0.5f) * extent.height;
		vk::Rect2D point = scene_cache_clip({ .offset = { (int)math::floor((double)sx) - 3,
			(int)math::floor((double)sy) - 3 }, .extent = { 7, 7 } }, extent);
		*rect = *found ? scene_cache_union(*rect, point) : point;
		*found = !scene_cache_empty(*rect);
	}
}

fn float scene_cache_intersection_plane(float[<4>] world, uint plane,
	collision::Aabb3 box, Matrix4f camera, Matrix4f light,
	float x0, float x1, float y0, float y1)
{
	if (plane < 6)
	{
		uint axis = plane / 2;
		float lo = axis == 0 ? box.min.x : (axis == 1 ? box.min.y : box.min.z);
		float hi = axis == 0 ? box.max.x : (axis == 1 ? box.max.y : box.max.z);
		return (plane & 1) == 0 ? world[axis] - lo : hi - world[axis];
	}
	float[<4>] p = plane < 12 ? camera * world : light * world;
	uint side = plane % 6;
	if (plane < 12) return scene_cache_clip_plane(p, side);
	switch (side)
	{
		case 0: return p[0] - x0 * p[3];
		case 1: return x1 * p[3] - p[0];
		case 2: return p[1] - y0 * p[3];
		case 3: return y1 * p[3] - p[1];
		case 4: return p[2];
		default: return p[3] - p[2];
	}
}

fn void scene_cache_clip_face(vk::Rect2D* rect, bool* found, float[<4>]* corners,
	uint face, collision::Aabb3 box, Matrix4f camera, Matrix4f light,
	float x0, float x1, float y0, float y1, vk::Extent2D extent)
{
	float[<4>][64] a;
	float[<4>][64] b;
	for (uint i = 0; i < 4; i++) a[i] = corners[SCENE_CACHE_BOX_FACES[face * 4 + i]];
	uint count = 4;
	bool ping = false;
	for (uint plane = 0; plane < 18 && count > 0; plane++)
	{
		float[<4>]* input = ping ? &b[0] : &a[0];
		float[<4>]* output = ping ? &a[0] : &b[0];
		uint written = 0;
		float[<4>] previous = input[count - 1];
		float previous_distance = scene_cache_intersection_plane(previous, plane,
			box, camera, light, x0, x1, y0, y1);
		for (uint i = 0; i < count; i++)
		{
			float[<4>] current = input[i];
			float distance = scene_cache_intersection_plane(current, plane,
				box, camera, light, x0, x1, y0, y1);
			bool previous_inside = previous_distance >= 0;
			bool current_inside = distance >= 0;
			if (previous_inside != current_inside)
			{
				float t = previous_distance / (previous_distance - distance);
				output[written++] = previous + (current - previous) * t;
			}
			if (current_inside) output[written++] = current;
			previous = current;
			previous_distance = distance;
		}
		count = written;
		ping = !ping;
	}
	float[<4>]* result = ping ? &b[0] : &a[0];
	for (uint i = 0; i < count; i++)
	{
		scene_cache_add_screen_point(rect, found, result[i], camera, extent);
	}
}

fn bool scene_cache_project_shadow_box(ShadowView* view, ShadowTile tile, ShadowRect changed,
	collision::Aabb3 box, Matrix4f camera, vk::Extent2D extent, vk::Rect2D* out)
{
	float u0 = (float)((int)changed.x - (int)tile.x) / (float)tile.size;
	float v0 = (float)((int)changed.y - (int)tile.y) / (float)tile.size;
	float u1 = (float)((int)(changed.x + changed.width) - (int)tile.x) / (float)tile.size;
	float v1 = (float)((int)(changed.y + changed.height) - (int)tile.y) / (float)tile.size;
	float x0 = u0 * 2 - 1;
	float x1 = u1 * 2 - 1;
	float y0 = 1 - v1 * 2;
	float y1 = 1 - v0 * 2;
	Matrix4f inverse_light = invert(view.view_projection);
	float[<4>][8] prism;
	float[<4>][8] bounds;
	for (uint corner = 0; corner < 8; corner++)
	{
		float[<4>] p = inverse_light * (float[<4>]) {
			(corner & 1) != 0 ? x1 : x0, (corner & 2) != 0 ? y1 : y0,
			(corner & 4) != 0 ? 1 : 0, 1 };
		prism[corner] = p / p[3];
		bounds[corner] = { (corner & 1) != 0 ? box.max.x : box.min.x,
			(corner & 2) != 0 ? box.max.y : box.min.y,
			(corner & 4) != 0 ? box.max.z : box.min.z, 1 };
	}
	bool found = false;
	*out = { };
	for (uint edge = 0; edge < 12; edge++)
	{
		uint ia = SCENE_CACHE_BOX_EDGES[edge * 2];
		uint ib = SCENE_CACHE_BOX_EDGES[edge * 2 + 1];
		float[<4>] a = prism[ia];
		float[<4>] b = prism[ib];
		if (scene_cache_clip_world_box(&a, &b, box))
		{
			scene_cache_add_segment(out, &found, a, b, camera, extent);
		}
		a = bounds[ia];
		b = bounds[ib];
		if (scene_cache_clip_shadow_prism(&a, &b, view.view_projection, x0, x1, y0, y1))
		{
			scene_cache_add_segment(out, &found, a, b, camera, extent);
		}
	}
	// When the receiver is wholly inside the camera, the first two edge families
	// are the complete box/prism intersection and camera clipping adds nothing.
	bool receiver_inside_camera = true;
	for (uint corner = 0; corner < 8 && receiver_inside_camera; corner++)
	{
		float[<4>] p = camera * bounds[corner];
		for (uint plane = 0; plane < 6; plane++)
		{
			if (scene_cache_clip_plane(p, plane) < 0) { receiver_inside_camera = false; break; }
		}
	}
	if (receiver_inside_camera) return found;
	// The third family of intersection vertices: a camera-frustum edge piercing
	// both the receiver and the shadow prism.
	Matrix4f inverse_camera = invert(camera);
	float[<4>][8] frustum;
	for (uint corner = 0; corner < 8; corner++)
	{
		float[<4>] p = inverse_camera * (float[<4>]) {
			(corner & 1) != 0 ? 1 : -1, (corner & 2) != 0 ? 1 : -1,
			(corner & 4) != 0 ? 1 : 0, 1 };
		frustum[corner] = p / p[3];
	}
	for (uint edge = 0; edge < 12; edge++)
	{
		float[<4>] a = frustum[SCENE_CACHE_BOX_EDGES[edge * 2]];
		float[<4>] b = frustum[SCENE_CACHE_BOX_EDGES[edge * 2 + 1]];
		if (!scene_cache_clip_world_box(&a, &b, box)) continue;
		if (!scene_cache_clip_shadow_prism(&a, &b, view.view_projection, x0, x1, y0, y1)) continue;
		scene_cache_add_segment(out, &found, a, b, camera, extent);
	}
	// Clip every original face against the other two volumes. Every vertex of a
	// three-convex-volume intersection is on at least one original face, including
	// the face/face/face vertices no original edge passes through.
	for (uint face = 0; face < 6; face++)
	{
		scene_cache_clip_face(out, &found, &bounds[0], face, box, camera,
			view.view_projection, x0, x1, y0, y1, extent);
		scene_cache_clip_face(out, &found, &prism[0], face, box, camera,
			view.view_projection, x0, x1, y0, y1, extent);
		scene_cache_clip_face(out, &found, &frustum[0], face, box, camera,
			view.view_projection, x0, x1, y0, y1, extent);
	}
	return found;
}

<*
 Compares the drawables after `prepare` has settled their matrices, materials and
 shadow update plan. Material changes are local to nodes which use that material.
*>
fn vk::Rect2D MeshPass.scene_cache_update(&self, SceneCache* cache, Target* target, ulong outer_state)
{
	ulong global = outer_state;
	// This is the normalized block the shaders actually read, so renderer modes
	// such as the LTC reference path and clustered-light fallback cannot reuse an
	// image produced with different global lighting behavior.
	global = hash_bytes(global, &self.scene_cache_frame, FrameBlock::size);
	global = @hash_value(global, self.frame_view_projection);
	global = @hash_value(global, self.scene != null ? self.scene.id : 0u);
	global = @hash_value(global, self.scene_rect);
	if (self.scene != null) global = @hash_value(global, self.scene.look.sky);
	global = @hash_value(global, self.lighting);
	global = @hash_value(global, self.assets.revision);
	global = @hash_value(global, self.debug_view);
	global = @hash_value(global, self.ambient_occlusion.live);
	global = @hash_value(global, self.ambient_occlusion.intensity);
	global = @hash_value(global, self.ambient_occlusion.radius);
	global = @hash_value(global, self.ambient_occlusion.bias);
	global = @hash_value(global, self.lightmap.revision);
	global = @hash_value(global, self.scene != null && self.scene.lightmap_live);
	cache.begin(target.extent, global);
	if (self.scene == null) return cache.finish();

	// A draw call consumes one contiguous instance array. Give every copy in it
	// the same color/variant key so a changed instance redraws that draw's bounds.
	if (cache.node_group_states.allocator == null) cache.node_group_states.init(mem, 64);
	while (cache.node_group_states.len() < self.scene.nodes.len()) cache.node_group_states.push(0);
	foreach (&state : cache.node_group_states) *state = 0;
	foreach (bucket : self.scene.buckets)
	{
		ulong look = KEY_SEED;
		for (uint i = 0; i < bucket.count; i++)
		{
			uint slot = self.scene.draws[(sz)(bucket.first + i)].slot;
			Node* node = &self.scene.nodes[slot];
			look = @hash_value(look, node.color);
			look = @hash_value(look, node.variant);
		}
		for (uint i = 0; i < bucket.count; i++)
		{
			uint slot = self.scene.draws[(sz)(bucket.first + i)].slot;
			cache.node_group_states[slot] = look;
		}
	}
	if (cache.material_states.allocator == null) cache.material_states.init(mem, 16);
	while (cache.material_states.len() < self.materials.len()) cache.material_states.push(0);
	foreach (material_slot, &material : self.materials)
	{
		ulong material_state = hash_bytes(KEY_SEED, material, Material::size);
		cache.material_states[material_slot] = hash_bytes(material_state,
			material.table.ptr, material.table.len);
	}
	ulong projection_base = hash_bytes(KEY_SEED, &self.frame_view_projection, Matrix4f::size);
	projection_base = @hash_value(projection_base, target.extent);
	projection_base = @hash_value(projection_base, self.assets.revision);
	projection_base = @hash_value(projection_base, self.ambient_occlusion.live);
	projection_base = @hash_value(projection_base, self.ambient_occlusion.radius);
	ulong static_receivers_state = KEY_SEED;

	foreach (slot, &node : self.scene.nodes)
	{
		if (!node.alive || !node.world_visible || node.collision_only) continue;
		GpuMesh* mesh = self.assets.mesh(node.asset, node.mesh);
		Material* material = self.material(node.material);
		if (mesh == null || material == null) continue;
		ulong identity = ((ulong)node.generation << 32) | (ulong)slot;
		ulong world_state = hash_bytes(KEY_SEED, &node.world, Matrix4f::size);
		ulong projection_state = @hash_value(projection_base, world_state);
		projection_state = @hash_value(projection_state, node.asset);
		projection_state = @hash_value(projection_state, node.mesh);
		projection_state = @hash_value(projection_state, mesh.bounds);
		projection_state = @hash_value(projection_state, material.bounds);
		if (node.skin >= 0) projection_state = @hash_value(projection_state, self.pose_content_key);
		if (node.morph != 0) projection_state = @hash_value(projection_state, self.morph_content_key);
		NodeId id = { (uint)slot, node.generation };
		SoftMesh* soft = self.scene.physics.soft_for(id);
		if (soft != null) projection_state = @hash_value(projection_state, self.soft_content_key);
		vk::Rect2D rect;
		collision::Aabb3 world_box;
		if (!cache.projected(identity, projection_state, &rect, &world_box))
		{
			collision::Aabb3 local = mesh.bounds;
			if (node.skin >= 0)
			{
				Asset* owner = self.assets.slot(node.asset);
				if (owner != null && owner.pose_matrices > 0) local = owner.skinned_bounds;
			}
			if (soft != null) local = soft.bounds;
			world_box = local.transform_matrix(node.world);
			collision::Aabb3 box = world_box;
			float margin = material.bounds;
			// AO can change receivers around a moving occluder, not only the pixels the
			// occluder covers. Its world-space search radius is the conservative growth.
			if (self.ambient_occlusion.live) margin += self.ambient_occlusion.radius;
			if (margin > 0)
			{
				float m = margin;
				box = { .min = box.min - { m,m,m }, .max = box.max + { m,m,m } };
			}
			(void)scene_cache_project_box(box, self.frame_view_projection, target.extent, 3, &rect);
		}
		ulong state = world_state;
		state = @hash_value(state, node.asset);
		state = @hash_value(state, node.mesh);
		state = @hash_value(state, node.static_caster);
		state = @hash_value(state, mesh.index_count);
		state = @hash_value(state, mesh.vertex_count);
		state = @hash_value(state, node.color);
		state = @hash_value(state, node.variant);
		state = @hash_value(state, node.pose);
		state = @hash_value(state, node.pose_from);
		state = @hash_value(state, node.blend);
		state = @hash_value(state, node.morph);
		state = @hash_value(state, node.lightmap);
		state = @hash_value(state, cache.node_group_states[slot]);
		state = @hash_value(state, cache.material_states[node.material]);
		// These buffers keep stable addresses while their contents move. Fold the
		// bytes' keys, never the clock as a proxy: captures can pose a character more
		// than once without advancing time.
		if (node.skin >= 0) state = @hash_value(state, self.pose_content_key);
		if (node.morph != 0) state = @hash_value(state, self.morph_content_key);
		if (soft != null) state = @hash_value(state, self.soft_content_key);
		if (material.reads_time)
		{
			state = @hash_value(state, self.clock.time);
		}
		cache.observe(identity, state, rect, projection_state, world_box);
		if (node.static_caster)
		{
			static_receivers_state = @hash_value(static_receivers_state, identity);
			static_receivers_state = @hash_value(static_receivers_state, projection_state);
		}
	}

	ShadowManager* manager = &self.shadow_manager;
	for (uint at = 0; at < self.shadow_view_set.count; at++)
	{
		if (!manager.scheduled[at]) continue;
		ShadowView* view = &self.shadow_view_set.views[at];
		ShadowTile tile = manager.tiles[at];
		ShadowRect changed = manager.update_rects[at];
		ulong static_key = hash_bytes(static_receivers_state,
			&view.view_projection, Matrix4f::size);
		static_key = hash_bytes(static_key, &tile, ShadowTile::size);
		static_key = hash_bytes(static_key, &changed, ShadowRect::size);
		bool reuse_static = cache.static_shadow_valid[at]
			&& cache.static_shadow_keys[at] == static_key;
		vk::Rect2D static_damage = reuse_static ? cache.static_shadow_rects[at] : (vk::Rect2D){};
		if (reuse_static) cache.touch(static_damage);
		vk::Rect2D shadow_screen;
		if (!scene_cache_project_shadow(view, tile, changed,
			self.frame_view_projection, target.extent, &shadow_screen)) continue;
		foreach (slot, &node : self.scene.nodes)
		{
			if (!node.alive || !node.world_visible || node.collision_only) continue;
			if (reuse_static && node.static_caster) continue;
			if (slot >= cache.items.len() || scene_cache_empty(cache.items[slot].rect)) continue;
			if (!scene_cache_overlaps(cache.items[slot].rect, shadow_screen)) continue;
			Material* material = self.material(node.material);
			if (material == null) continue;
			collision::Aabb3 box = cache.items[slot].world_box;
			float margin = material.bounds + 0.02f;
			box = { .min = box.min - {margin,margin,margin}, .max = box.max + {margin,margin,margin} };
			if (!scene_cache_shadow_reaches_box(view, tile, changed, box)) continue;
			vk::Rect2D rect;
			if (scene_cache_project_shadow_box(view, tile, changed, box,
				self.frame_view_projection, target.extent, &rect))
			{
				if (node.static_caster) { static_damage = scene_cache_union(static_damage, rect); }
				else { cache.touch(rect); }
			}
		}
		if (!reuse_static)
		{
			cache.static_shadow_keys[at] = static_key;
			cache.static_shadow_rects[at] = static_damage;
			cache.static_shadow_valid[at] = true;
			cache.touch(static_damage);
		}
	}
	return cache.finish();
}
