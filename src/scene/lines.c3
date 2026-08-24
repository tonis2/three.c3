<*
 Line geometry: the shapes a scene is debugged with rather than built out of.

 ## Why this is geometry at all, and not a debug renderer

 Every engine's debug draw is an immediate-mode side channel — a list of segments
 refilled each frame, uploaded each frame, drawn outside the scene. That would be
 a second renderer here, with its own buffer growth, its own frame-slot problem
 (`gpu/frame.c3`'s, the one that tore crig's pose palette) and its own answer to
 "how many draw calls was that".

 It is not needed. A debug box is a shape, and this project already has one path
 for shapes: tessellate once, file the result under a key, and let every use of
 the same key share the asset. So a helper is an ordinary `Mesh` over an ordinary
 asset, and the properties fall out rather than being re-engineered:

 - **A thousand box helpers are one draw call.** They share the unit-cube asset
   and differ by transform, which is the same claim `plan.md` makes about a
   thousand walls.
 - **Colour is free per copy.** `mesh.color` already rides in the instance record,
   so red boxes and green boxes are still one draw call — which is what makes
   `AxesHelper` three meshes over *one* segment asset rather than three assets.
 - **`scene.remove(helper)` works**, and `unloadUnused` gives the memory back,
   because there is nothing special about these assets.

 ## Unit shapes, scaled — not shapes built to size

 `BoxHelper` around a 3 x 0.2 x 7 wall does not tessellate a 3 x 0.2 x 7 wireframe.
 It places the unit cube with `scale` set to the box's size, because otherwise
 every distinct object size would be its own asset and its own draw call, and a
 scene of two hundred kit pieces would end with two hundred box assets whose only
 purpose was to be looked at.

 The grid is keyed on its *divisions* alone for the same reason: `GridHelper(100, 10)`
 and `GridHelper(40, 10)` are one asset at two scales.

 ## Lines, not a fill mode

 `PRIMITIVE_TOPOLOGY_LINE_LIST` and an index buffer of pairs. `plan.md` §1
 settled this before there was anything to draw: `fillModeNonSolid` is false on
 the bundled KosmicKrisp, so `POLYGON_MODE_LINE` is not available, and `wideLines`
 is false too — so every line here is one pixel and there is no width to set.
*>
module three;

import std::math;
import std::math::vector;
import std::collections::list;
import std::sort;
import collision;

faultdef NO_SUCH_LINE_MESH, LINE_MESH_NOT_RESIDENT, NO_SUCH_LINE_SHAPE;

<*
 The shapes that come as lines.

 Three, and no more than three on purpose: a box says where something ends, an
 axis says where its pivot is and which way it faces, and a grid says where the
 ground is and how big a metre looks. A fourth would want a reason of its own.
*>
enum LineKind
{
	BOX,
	SEGMENT,
	GRID,
}

<*
 A line shape before it is built.

 `divisions` is read by the grid and ignored by the other two, which is why it is
 in the key only for the grid — a box that carried a meaningless division count
 would file two identical assets under two keys.
*>
struct LineShape
{
	LineKind kind;
	uint divisions;
}

// A grid finer than this is a wall of pixels rather than a reference, and the
// vertex count is 4 * (divisions + 1), so a mistyped literal is still bounded.
const uint MAX_GRID_DIVISIONS = 256;

fn String LineShape.key(&self, Allocator allocator)
{
	switch (self.kind)
	{
		case LineKind.BOX: return "<lines box>".copy(allocator);
		case LineKind.SEGMENT: return "<lines segment>".copy(allocator);
		case LineKind.GRID: return string::format(allocator, "<lines grid %d>", self.divisions);
		default: return "<lines>".copy(allocator);
	}
}

<*
 The name a script spells, as a kind.

 `primitive_kind`'s twin, and the same three-line switch, because the crossing is
 the same one: `prelude.js` names a shape and the host is the place that knows
 whether the name is one it builds.

 @return? NO_SUCH_LINE_SHAPE : `Not one of box, segment or grid.`
*>
fn LineKind? line_kind(String name)
{
	switch (name)
	{
		case "box": return LineKind.BOX;
		case "segment": return LineKind.SEGMENT;
		case "grid": return LineKind.GRID;
		default: return NO_SUCH_LINE_SHAPE~;
	}
}

fn String LineShape.label(&self)
{
	switch (self.kind)
	{
		case LineKind.BOX: return "box";
		case LineKind.SEGMENT: return "segment";
		case LineKind.GRID: return "grid";
		default: return "lines";
	}
}

// ============================================================================
// Building
// ============================================================================

<*
 A vertex with no normal and no uv.

 The absence is what makes the line flat-shaded. `Assets.upload_built` decides a
 stream exists by comparing its length against the position count, so a builder
 that never pushes a normal produces `has_normals = false` and `mesh.slang`'s
 unlit branch — which is what a debug line wants. Pushing a normal here would
 light the wireframe, and a wireframe that is dark on one side is a worse
 diagnostic than one that is not.
*>
fn uint GeometryBuilder.line_vertex(&self, Vec3 position)
{
	uint at = (uint)self.positions.len();
	self.positions.push(position);
	return at;
}

fn void GeometryBuilder.segment(&self, uint a, uint b)
{
	self.indices.push(a);
	self.indices.push(b);
}

fn void LineShape.build(&self, GeometryBuilder* out)
{
	switch (self.kind)
	{
		case LineKind.BOX: build_line_box(out);
		case LineKind.SEGMENT: build_line_segment(out);
		case LineKind.GRID: build_line_grid(out, self.divisions);
		default: break;
	}
}

<*
 The twelve edges of a unit cube about the origin, corners at +/- 0.5.

 The same extent `BoxGeometry(1, 1, 1)` has, which is what lets a helper be
 placed by copying a box's centre into `position` and its size into `scale` with
 no factor of two anywhere.
*>
fn void build_line_box(GeometryBuilder* out) @local
{
	// Bit i of the corner index selects the high side of axis i, so corner ^ (1 << axis)
	// is the neighbour along that axis and the twelve edges are every pair that
	// differs in exactly one bit.
	for (uint corner = 0; corner < 8; corner++)
	{
		out.line_vertex({
			(corner & 1) != 0 ? 0.5f : -0.5f,
			(corner & 2) != 0 ? 0.5f : -0.5f,
			(corner & 4) != 0 ? 0.5f : -0.5f,
		});
	}

	for (uint corner = 0; corner < 8; corner++)
	{
		for (uint axis = 0; axis < 3; axis++)
		{
			uint other = corner ^ (1u << axis);
			// Each edge once, from its low end, rather than twice.
			if (other > corner) out.segment(corner, other);
		}
	}
}

<*
 One segment, origin to +X, one unit long.

 +X rather than +Y so that "the length is the X scale" is true, and so that the
 three axes of an `AxesHelper` are one asset turned three ways rather than three
 assets.
*>
fn void build_line_segment(GeometryBuilder* out) @local
{
	out.line_vertex({ 0, 0, 0 });
	out.line_vertex({ 1, 0, 0 });
	out.segment(0, 1);
}

<*
 A unit square in the XZ plane, ruled `divisions` times each way.

 Three.js's `GridHelper` plane, so a script that has memorized it is not
 surprised by a grid standing on edge. One unit across, for the header's reason —
 the size is the transform's job.
*>
fn void build_line_grid(GeometryBuilder* out, uint divisions) @local
{
	uint cells = divisions < 1 ? 1 : (divisions > MAX_GRID_DIVISIONS ? MAX_GRID_DIVISIONS : divisions);

	for (uint i = 0; i <= cells; i++)
	{
		float at = (float)i / (float)cells - 0.5f;

		uint a = out.line_vertex({ -0.5f, 0, at });
		uint b = out.line_vertex({ 0.5f, 0, at });
		out.segment(a, b);

		uint c = out.line_vertex({ at, 0, -0.5f });
		uint d = out.line_vertex({ at, 0, 0.5f });
		out.segment(c, d);
	}
}

// ============================================================================
// Uploading
// ============================================================================

<*
 Build a line shape and upload it — or answer with the one already built.

 `Assets.primitive`'s twin, and deliberately the same shape: one key, one lookup,
 one `upload_built`. A line asset and a triangle asset are indistinguishable
 afterwards except in their index buffers, which is what lets `unloadUnused`,
 `stats()` and the refcount know nothing about any of this.

 @return `The asset's handle, for Scene.add_mesh.`
*>
fn AssetId? Assets.lines(&self, Gpu* gpu, LineShape shape)
{
	if (!self.started) self.init();

	@pool()
	{
		String key = shape.key(tmem);
		if (try hit = self.built(key)) return hit;

		GeometryBuilder geometry;
		geometry.init();
		defer geometry.free();
		shape.build(&geometry);

		return self.upload_built(gpu, key, shape.label(), &geometry, lines: true);
	};
}

<*
 One mesh's triangles, as the edges between them.

 The tool for the failure that started this: two faces 0.01 apart z-fighting into
 a starburst, which is invisible in a solid render and obvious the moment the
 edges are drawn — `LINE_STATE` tests no depth, so the wireframe sits over the
 surface it describes rather than fighting it.

 ## It reads the CPU copy, and that is why the mesh has to be resident

 `hull_positions` and `hull_triangles` are kept per mesh for picking and hulls
 (`GpuMesh.build_bvh`), so the triangles are already here and nothing is read
 back from the device. But they are filled at *upload*, and a mesh reaches the
 device only when something drawing it is added to a scene — so a wireframe of a
 mesh nobody has placed yet has nothing to read. That is a sentence rather than
 an empty mesh, because an empty mesh would draw nothing and read as a helper
 that does not work.

 ## Edges are deduplicated, and the sort is the cheap way

 Every interior edge is shared by two triangles, so emitting three per triangle
 draws each of them twice and doubles the index buffer. Sorting the packed
 `(low, high)` pairs and skipping repeats halves it in `n log n` with one
 allocation, against a hash map's per-edge one.

 @return? NO_SUCH_LINE_MESH : `The handle names no mesh — a stale asset, or an index past the end of the file.`
 @return? LINE_MESH_NOT_RESIDENT : `That mesh's triangles are not on this side. Add something that draws it to the scene first.`
*>
fn AssetId? Assets.wireframe(&self, Gpu* gpu, AssetId asset, uint mesh)
{
	GpuMesh* source = self.mesh(asset, mesh);
	if (source == null) return NO_SUCH_LINE_MESH~;
	if (source.hull_positions.len == 0 || source.hull_triangles.len == 0) return LINE_MESH_NOT_RESIDENT~;

	@pool()
	{
		// The source asset's own path and mesh index, so re-exporting the file
		// under the same name reuses the key exactly as the mesh itself does —
		// and so a stats dump names what the wireframe is *of*.
		String key = string::tformat("<wireframe %s#%d>", self.slot(asset).path, mesh);
		if (try hit = self.built(key)) return hit;

		GeometryBuilder geometry;
		geometry.init();
		defer geometry.free();

		foreach (position : source.hull_positions) geometry.line_vertex(position);

		List{ulong} edges;
		edges.tinit((sz)source.hull_triangles.len * 3);
		foreach (triangle : source.hull_triangles)
		{
			uint[3] corner = { triangle[0], triangle[1], triangle[2] };
			for (uint i = 0; i < 3; i++)
			{
				uint from = corner[i];
				uint to = corner[(i + 1) % 3];
				// Ordered before packing, so the same edge seen from either
				// triangle packs to the same number and the dedup is exact.
				edges.push(from < to ? ((ulong)from << 32) | to : ((ulong)to << 32) | from);
			}
		}

		// Merge rather than quick for `Scene.build_draw_list`'s reason: the packed
		// edges arrive in triangle order, which for a grid — a terrain, a plane —
		// is already ascending over long stretches, and that is the input
		// `std::sort::quicksort` degrades to quadratic on.
		sort::mergesort(edges.array_view());

		ulong previous = 0;
		bool started = false;
		foreach (edge : edges)
		{
			if (started && edge == previous) continue;
			previous = edge;
			started = true;
			geometry.segment((uint)(edge >> 32), (uint)(edge & 0xffffffff));
		}

		return self.upload_built(gpu, key, "wireframe", &geometry, lines: true);
	};
}
