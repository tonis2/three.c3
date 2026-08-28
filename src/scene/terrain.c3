<*
 Ground that is a surface rather than a pile of boxes.

 Paving a scene's ground with `BoxGeometry` copies — the only shape a script
 could otherwise stand something on — costs three things. A 3249-tile ground
 measured 1.1 ms a frame of pure shadow fill, from around thirteen thousand side
 faces buried inside their own neighbours and rasterised into the map anyway. A
 slope across four-unit tiles is a flight of steps, so rolling hills have to
 become a treeline. And the height query, the collider and the mesh end up as
 separate hand-written functions that nothing can catch disagreeing.

 A `Heightfield` is one asset, one draw call, and one source of truth for all
 three.

 ## The grid

 `(segments + 1)^2` samples over `width` x `depth`, centred on the origin, in the
 xz plane with +y up — the frame `PlaneGeometry` lands in after the rotation every
 script writes. It is baked in because a terrain that could be authored on its
 side is a terrain whose `height_at` means nothing.

 Normals come from the grid, not from the triangles, and that is the difference
 between ground and steps: a vertex normal is the central difference of its four
 neighbours, so the surface shades as the smooth thing the samples describe
 rather than the faceted thing the triangles are.

 ## `height_at` cannot disagree with the mesh

 It reads the same array through the same bilinear interpolation the two
 triangles of a cell perform between the same four corners — not "kept in step
 with", the same numbers.

 It is an approximation only inside a cell: a quad split into two triangles is
 not a bilinear patch, and the two differ by at most the cell's own twist.
 Sub-cell, and the same difference the physics engine's own heightfield makes.
*>
module three;

import std::math;
import std::math::vector;
import std::collections::list;
import collision;

<*
 Beyond this many cells a side, a heightfield is a memory bomb rather than
 terrain: 512 is 263 169 samples and about five megabytes of vertices, and 4096
 would be sixteen million.

 The prelude refuses past this with a sentence; the clamp here is the backstop
 for a forged call, as `primitive_segments` has.
*>
const uint MAX_TERRAIN_SEGMENTS = 512;
const uint MIN_TERRAIN_SEGMENTS = 1;

faultdef TERRAIN_SIZE_INVALID, TERRAIN_HEIGHTS_WRONG_LENGTH;

<*
 A grid of heights, and everything derived from it.

 The list is owned. `Assets.free_slot` frees it with the asset that holds it, so
 a query on a handle to an unloaded asset finds nothing rather than freed memory.
*>
struct Heightfield
{
	// World extent along x and z. The field spans [-width/2, width/2].
	float width;
	float depth;
	// Cells per side. There are `segments + 1` samples per side.
	uint segments;
	<*
	 How far the border wall drops below the lowest sample, in world units, or 0
	 for no wall.

	 A map edge should be a wall and not a hole. Without it the ground ends in a
	 one-pixel line and the camera sees the sky through the seam from any angle
	 below the horizon, which reads as a rendering bug rather than the edge of
	 the world.
	*>
	float skirt;
	// `(segments + 1) * (segments + 1)` of them, row-major in z then x.
	List{float} heights;
}

fn uint Heightfield.side(&self) @inline => self.segments + 1;

<*
 The height at a grid index, with the edges extended outwards.

 Clamped rather than wrapped or zeroed. A query outside the field is a character
 walking off the map, and the honest answer is the ground it last stood on: zero
 would drop it through the floor at the boundary, and wrapping would teleport the
 ground under it.
*>
fn float Heightfield.sample(&self, int i, int j)
{
	int last = (int)self.segments;
	if (i < 0) i = 0;
	if (j < 0) j = 0;
	if (i > last) i = last;
	if (j > last) j = last;
	sz at = (sz)j * (sz)self.side() + (sz)i;
	if (at >= self.heights.len()) return 0;
	return self.heights[at];
}

<*
 Where a world x or z falls on the grid, in cells.

 Returned as a float so the caller keeps the fraction: the integer part is the
 cell and the fraction is the position inside it, and computing them separately
 is how the two end up disagreeing at a cell boundary.
*>
fn float Heightfield.grid_x(&self, float x) @inline
	=> (x + self.width * 0.5f) / self.width * (float)self.segments;

fn float Heightfield.grid_z(&self, float z) @inline
	=> (z + self.depth * 0.5f) / self.depth * (float)self.segments;

fn float Heightfield.cell_x(&self) @inline => self.width / (float)self.segments;
fn float Heightfield.cell_z(&self) @inline => self.depth / (float)self.segments;

<*
 The ground at a world (x, z).

 Everything that stands outdoors needs it: buildings, fence posts, trees, NPCs.
 It is also what makes `align('y', 'min')` mean anything on open ground.

 Bilinear, so it is continuous everywhere — a query that stepped to the nearest
 sample would put a character through a staircase on a smooth hill, which is the
 defect the boxes had.
*>
fn float Heightfield.height_at(&self, float x, float z)
{
	float gx = self.grid_x(x);
	float gz = self.grid_z(z);
	int i = (int)math::floor(gx);
	int j = (int)math::floor(gz);
	float fx = gx - (float)i;
	float fz = gz - (float)j;

	float h00 = self.sample(i, j);
	float h10 = self.sample(i + 1, j);
	float h01 = self.sample(i, j + 1);
	float h11 = self.sample(i + 1, j + 1);

	float top = h00 + (h10 - h00) * fx;
	float bottom = h01 + (h11 - h01) * fx;
	return top + (bottom - top) * fz;
}

<*
 The surface normal at a grid index, from its four neighbours.

 The central difference over two cells rather than the forward difference over
 one: a forward difference makes a normal that belongs half a cell away, tilting
 every lit surface consistently in one direction — a scene that looks lit from
 the wrong place, with nothing to say why.

 At the border the clamp in `sample` turns the central difference into a forward
 one, which is the right degeneracy: the edge normal leans the way the last real
 cell does.
*>
fn Vec3 Heightfield.grid_normal(&self, int i, int j)
{
	float dx = (self.sample(i + 1, j) - self.sample(i - 1, j)) / (2.0f * self.cell_x());
	float dz = (self.sample(i, j + 1) - self.sample(i, j - 1)) / (2.0f * self.cell_z());
	Vec3 n = { -dx, 1.0f, -dz };
	return n.normalize();
}

<*
 The surface normal at a world (x, z), interpolated exactly as the shading is.

 Bilinear over the same four vertex normals the rasteriser blends between, so a
 script placing something flush with the ground agrees with what the light does
 to it. Re-normalized after the blend, because interpolating unit vectors does
 not produce one.
*>
fn Vec3 Heightfield.normal_at(&self, float x, float z)
{
	float gx = self.grid_x(x);
	float gz = self.grid_z(z);
	int i = (int)math::floor(gx);
	int j = (int)math::floor(gz);
	float fx = gx - (float)i;
	float fz = gz - (float)j;

	Vec3 n00 = self.grid_normal(i, j);
	Vec3 n10 = self.grid_normal(i + 1, j);
	Vec3 n01 = self.grid_normal(i, j + 1);
	Vec3 n11 = self.grid_normal(i + 1, j + 1);

	Vec3 top = n00 + (n10 - n00) * fx;
	Vec3 bottom = n01 + (n11 - n01) * fx;
	Vec3 blended = top + (bottom - top) * fz;
	float length = blended.length();
	return length > 1e-6f ? blended * (1.0f / length) : (Vec3){ 0, 1, 0 };
}

<*
 The world box the field occupies, for culling and for `Scene.bounds`.

 The low corner includes the skirt, because the skirt is geometry and a box that
 did not contain it would cull the wall out from under the ground at a grazing
 angle.
*>
fn collision::Aabb3 Heightfield.bounds(&self)
{
	float low = 0;
	float high = 0;
	foreach (i, height : self.heights)
	{
		if (i == 0 || height < low) low = height;
		if (i == 0 || height > high) high = height;
	}
	return {
		.min = { -self.width * 0.5f, low - self.skirt, -self.depth * 0.5f },
		.max = { self.width * 0.5f, high, self.depth * 0.5f },
	};
}

<*
 Writes the surface into a builder — the same one every generated shape uses.

 One grid of vertices shared by every triangle, so a 128-cell field is 16 641
 vertices rather than the 98 304 six separate faces would be. The uv runs 0..1
 across the whole field, which makes a splat mask authored at any resolution line
 up with the ground without a transform.

 The skirt is a separate ring of vertices rather than a reuse of the border row,
 because the wall's normal points outwards and the ground's points up: sharing
 them would round the edge over and light the wall as though it were ground.
*>
fn void Heightfield.build(&self, GeometryBuilder* out)
{
	uint side = self.side();
	float half_w = self.width * 0.5f;
	float half_d = self.depth * 0.5f;

	for (uint j = 0; j < side; j++)
	{
		for (uint i = 0; i < side; i++)
		{
			float u = (float)i / (float)self.segments;
			float v = (float)j / (float)self.segments;
			out.vertex(
				{ -half_w + u * self.width, self.sample((int)i, (int)j), -half_d + v * self.depth },
				self.grid_normal((int)i, (int)j),
				{ u, v }
			);
		}
	}

	for (uint j = 0; j < self.segments; j++)
	{
		for (uint i = 0; i < self.segments; i++)
		{
			uint a = j * side + i;
			uint b = a + 1;
			uint c = a + side;
			uint d = c + 1;
			// Counter-clockwise seen from +y, which is the front face
			// `render/pass.c3` keeps — the same winding `build_face` uses,
			// arrived at by the same right-hand rule.
			out.triangle(a, c, b);
			out.triangle(b, c, d);
		}
	}

	if (self.skirt > 0) self.build_skirt(out);
}

<*
 A wall around the border, dropping to `skirt` below the lowest sample.

 Four strips, each walked so its front face points away from the field.

 ## The uv is the border texel, and the wall has no area in uv space

 A wall vertex takes the uv of the point on the *field* it hangs from — top and
 bottom alike — so a strip is a line rather than a rectangle in uv, and a splat
 mask reaches down the wall in the colour of the edge it belongs to. That is the
 answer somebody painting a mask would expect, and it is the only one that leaves
 `Heightfield.build`'s promise true: the uv runs 0..1 across the whole field, and
 across nothing else.

 It used to run 0..1 down each wall instead, which put four more copies of the
 unit square on top of the field's one. Nothing in a frame noticed, because a
 wall is normally below the sand and out of sight. `scene.export({ bake: ... })`
 noticed immediately: a bake rasterises a mesh *by its uv*, so the four walls
 were drawn over the whole texture after the ground was, and a beach came out as
 vertical stripes of the cliff behind it.
*>
fn void Heightfield.build_skirt(&self, GeometryBuilder* out)
{
	uint side = self.side();
	float half_w = self.width * 0.5f;
	float half_d = self.depth * 0.5f;
	float floor_y = self.bounds().min.y;

	// edge 0: -z, normal -z, walked +x. 1: +z, normal +z, walked -x.
	// 2: -x, normal -x, walked -z. 3: +x, normal +x, walked +z.
	for (uint edge = 0; edge < 4; edge++)
	{
		Vec3 normal = { 0, 0, 0 };
		switch (edge)
		{
			case 0: normal = { 0, 0, -1 };
			case 1: normal = { 0, 0, 1 };
			case 2: normal = { -1, 0, 0 };
			default: normal = { 1, 0, 0 };
		}

		uint first = (uint)out.positions.len();
		for (uint step = 0; step < side; step++)
		{
			uint i;
			uint j;
			switch (edge)
			{
				case 0: i = step; j = 0;
				case 1: i = self.segments - step; j = self.segments;
				case 2: i = 0; j = self.segments - step;
				default: i = self.segments; j = step;
			}
			float x = -half_w + (float)i / (float)self.segments * self.width;
			float z = -half_d + (float)j / (float)self.segments * self.depth;
			float y = self.sample((int)i, (int)j);
			float u = (float)i / (float)self.segments;
			float v = (float)j / (float)self.segments;
			out.vertex({ x, y, z }, normal, { u, v });
			out.vertex({ x, floor_y, z }, normal, { u, v });
		}
		for (uint step = 0; step + 1 < side; step++)
		{
			uint a = first + step * 2;
			uint b = a + 1;
			uint c = a + 2;
			uint d = a + 3;
			out.triangle(a, b, c);
			out.triangle(b, d, c);
		}
	}
}

<*
 Builds a heightfield and uploads it as an asset.

 Through `upload_built`, so a terrain is an asset like any other: one draw call,
 one bucket, no new pipeline, and `split.c3`, the exporter and the picking tree
 all read it through the paths they already have. That is why this is a
 `GeometryBuilder` and not a pass of its own.

 The key is the parameters plus a hash of the heights, so two identical fields
 are one asset. A collision would hand back the wrong terrain, so the hash is
 64-bit FNV over the raw floats rather than anything cheaper; at one field per
 scene the birthday bound is not close.

 The field is kept on the slot because `height_at` is the point.
 `Assets.free_slot` frees the list with the asset.

 @param field : `Borrowed. The list is copied onto the asset, so the caller keeps ownership of theirs.`
 @return? TERRAIN_SIZE_INVALID : `A non-positive extent, or a segment count outside 1..MAX_TERRAIN_SEGMENTS.`
 @return? TERRAIN_HEIGHTS_WRONG_LENGTH : `The height array is not exactly (segments + 1)^2 long — the one mistake that would otherwise read a plausible surface off the wrong stride.`
*>
fn AssetId? Assets.terrain(&self, Gpu* gpu, Heightfield* field)
{
	if (!self.started) self.init();

	if (field.width <= 0 || field.depth <= 0) return TERRAIN_SIZE_INVALID~;
	if (field.segments < MIN_TERRAIN_SEGMENTS || field.segments > MAX_TERRAIN_SEGMENTS) return TERRAIN_SIZE_INVALID~;

	sz wanted = (sz)field.side() * (sz)field.side();
	if (field.heights.len() != wanted) return TERRAIN_HEIGHTS_WRONG_LENGTH~;

	@pool()
	{
		ulong hash = 0xcbf29ce484222325u;
		foreach (height : field.heights)
		{
			uint bits = bitcast(height, uint);
			for (uint byte = 0; byte < 4; byte++)
			{
				hash ^= (ulong)((bits >> (byte * 8)) & 0xff);
				hash *= 0x100000001b3u;
			}
		}
		String key = string::tformat(
			"terrain:%f:%f:%d:%f:%x", field.width, field.depth, field.segments, field.skirt, hash
		);
		if (try hit = self.built(key)) return hit;

		GeometryBuilder geometry;
		geometry.init();
		defer geometry.free();
		field.build(&geometry);

		AssetId built = self.upload_built(gpu, key, "terrain", &geometry)!;

		Asset* slot = self.slot(built);
		slot.terrain = {
			.width = field.width,
			.depth = field.depth,
			.segments = field.segments,
			.skirt = field.skirt,
		};
		slot.terrain.heights.init(mem, (usz)wanted);
		foreach (height : field.heights) slot.terrain.heights.push(height);
		slot.has_terrain = true;
		return built;
	};
}

<*
 The heightfield behind an asset, or null.

 Null for every asset that is not a terrain, which is the same answer a query on
 a stale `AssetId` gets — `slot` has already checked the generation, so a handle
 to an unloaded terrain finds nothing rather than a freed list.
*>
fn Heightfield* Assets.terrain_field(&self, AssetId id)
{
	Asset* slot = self.slot(id);
	if (slot == null || !slot.has_terrain) return null;
	return &slot.terrain;
}
