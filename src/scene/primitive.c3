<*
 Parametric shapes — the geometry an agent asks for by name rather than by file.

 What crosses from JavaScript is a shape's *name and its numbers*; what comes
 back is an ordinary asset index, indistinguishable from one `three.load`
 produced. No script can read a vertex, write one, or hand an array of them over.

 ## One asset per parameter set

 The habit an agent arrives with is a fresh geometry per mesh —
 `new THREE.Mesh(new THREE.BoxGeometry(1, 1, 1), mat)` inside a loop. Under
 Three.js that is N uploads and N draws unless the author knows to reach for
 `InstancedMesh`. Here the built mesh is keyed by its parameters, and the second
 identical `BoxGeometry` answers with the first one's asset index — so the naive
 loop is one upload and one instanced draw, and the habit produces the fast scene
 without the agent knowing why. `Primitive.key` is where that is struck.

 The key is the parameters, formatted. Six decimals is therefore the resolution
 at which two shapes are the same shape: boxes 1.0 and 1.0000001 wide share an
 asset. That is deliberate — a bit-exact key would make a width computed as
 `3 / 3` and one written as `1` two uploads and two draw calls, a performance
 cliff that depends on floating-point history and is invisible from JavaScript.

 ## Three.js's formulas, copied rather than re-derived

 Positions, winding, UV layout and orientation are Three.js's: a plane faces +Z,
 a cylinder's axis is Y, a torus lies in the XY plane, a sphere's north pole is
 +Y, a cone's point is up. An agent that has memorised Three.js has memorised
 those too, and a shape that is the right size and the wrong way up is a bug it
 has no reason to look for.

 Copying carries the winding across for free, and that matters more here.
 `render/pass.c3` builds the pipeline with `CULL_MODE_BACK_BIT` and
 `FRONT_FACE_COUNTER_CLOCKWISE`, so a face wound the wrong way is not a dark
 patch — it is a hole you can see the inside of the object through. Every
 grid-shaped face below emits `(a, b, d)` and `(b, c, d)` over a frame whose
 `u × v = normal`, which is the invariant that keeps all six sides of a box, both
 caps of a cylinder and every quad of a sphere facing outward.
 `every_generated_face_points_outward` asserts it against the triangles
 themselves rather than against a picture.
*>
module three;

import std::math;
import std::math::vector;
import std::collections::list;
import collision;

faultdef PRIMITIVE_HAS_NO_TRIANGLES, NO_SUCH_PRIMITIVE, NOTHING_BUILT_UNDER_THAT_KEY;

<*
 What a shape is called, on both sides of the binding.

 There is no `CONE`: a cone is a cylinder with a top radius of zero, which is
 what Three.js's `ConeGeometry` is too. Normalising it here rather than carrying
 a sixth kind means `new three.ConeGeometry(1, 2)` and
 `new three.CylinderGeometry(0, 1, 2)` produce one asset and therefore one draw
 call, instead of two uploads of the same triangles.
*>
enum PrimitiveKind
{
	BOX,
	SPHERE,
	PLANE,
	CYLINDER,
	TORUS,
}

fn String PrimitiveKind.label(self)
{
	switch (self)
	{
		case PrimitiveKind.BOX: return "box";
		case PrimitiveKind.SPHERE: return "sphere";
		case PrimitiveKind.PLANE: return "plane";
		case PrimitiveKind.CYLINDER: return "cylinder";
		case PrimitiveKind.TORUS: return "torus";
		default: return "primitive";
	}
}

<*
 A name for a shape, as the JS binding spells it.

 @return ? NO_SUCH_PRIMITIVE : `The caller made the name up — js_primitive answers with the list of real ones.`
*>
fn PrimitiveKind? primitive_kind(String name)
{
	switch (name)
	{
		case "box": return PrimitiveKind.BOX;
		case "sphere": return PrimitiveKind.SPHERE;
		case "plane": return PrimitiveKind.PLANE;
		case "cylinder": return PrimitiveKind.CYLINDER;
		case "torus": return PrimitiveKind.TORUS;
		default: return NO_SUCH_PRIMITIVE~;
	}
}

<*
 Beyond this many segments on one axis a shape is a memory bomb rather than a
 mesh: a sphere at 4096 x 4096 is sixteen million vertices and four hundred
 megabytes of device memory, asked for by a typo in a number literal.

 `prelude.js` refuses anything above this with a sentence naming the cap; the
 clamp in `primitive_segments` is the backstop for a script that reaches past the
 prelude and calls `__three.primitive` itself.
*>
const uint MAX_PRIMITIVE_SEGMENTS = 512;

<*
 The base colour a generated shape draws with, in the absence of a material.

 Light neutral grey rather than the triangle's orange: these are what a scene
 gets built out of, and a scene of orange boxes reads as "something is wrong with
 the material" to an agent looking at its own screenshot.

 Stated in sRGB and converted where it is used. `GpuMesh.base_color` is a linear
 factor, because its dominant source is a glTF `baseColorFactor` and the
 specification defines that linear. Writing 0.5711 here would be the same colour
 and unreadable, so the number stays the one a colour picker shows and
 `srgb_to_linear_rgb` runs at the assignment.
*>
const float[4] PRIMITIVE_COLOR = { 0.78, 0.78, 0.80, 1.0 };

<*
 One shape, before it is built: what `new three.BoxGeometry(2, 1, 2)` names.

 The fields are deliberately not called `width`/`height`/`depth`. Five shapes
 share them and each reads them differently — `a` is a box's width, a sphere's
 radius, a cylinder's *top* radius and a torus's ring radius — so a name that
 fitted one would be a lie in the other four. The constructors below are where
 the names live, and are the only intended way to fill this in.
*>
struct Primitive
{
	PrimitiveKind kind;
	// Sizes, world units.
	float a;
	float b;
	float c;
	// Tessellation, per axis.
	uint u;
	uint v;
	uint w;
	// Cylinders only: whether the flat ends are generated. Three.js spells this
	// `openEnded` and means the opposite; the positive form is used here because a
	// field that is false by default and means "has caps" is a trap for whoever
	// fills the struct in without reading this.
	bool capped;
}

<*
 A box, `width` x `height` x `depth`, centred on the origin.
*>
fn Primitive box_shape(
	float width,
	float height,
	float depth,
	uint width_segments = 1,
	uint height_segments = 1,
	uint depth_segments = 1
)
{
	return {
		.kind = PrimitiveKind.BOX,
		.a = width,
		.b = height,
		.c = depth,
		.u = primitive_segments(width_segments, 1),
		.v = primitive_segments(height_segments, 1),
		.w = primitive_segments(depth_segments, 1),
	};
}

<*
 A UV sphere of `radius`, centred on the origin, poles on the Y axis.
*>
fn Primitive sphere_shape(float radius, uint width_segments = 32, uint height_segments = 16)
{
	return {
		.kind = PrimitiveKind.SPHERE,
		.a = radius,
		.u = primitive_segments(width_segments, 3),
		.v = primitive_segments(height_segments, 2),
		.w = 1,
	};
}

<*
 A flat rectangle in the XY plane, facing +Z — Three.js's orientation, which is
 vertical. A floor is this rotated -90 degrees about X.
*>
fn Primitive plane_shape(float width, float height, uint width_segments = 1, uint height_segments = 1)
{
	return {
		.kind = PrimitiveKind.PLANE,
		.a = width,
		.b = height,
		.u = primitive_segments(width_segments, 1),
		.v = primitive_segments(height_segments, 1),
		.w = 1,
	};
}

<*
 A cylinder, cone or truncated cone about the Y axis, centred on the origin.

 `radius_top` of zero is a cone with its point up, `radius_bottom` of zero is one
 with its point down, and either way the degenerate ring of triangles at the tip
 is dropped rather than emitted as slivers.
*>
fn Primitive cylinder_shape(
	float radius_top,
	float radius_bottom,
	float height,
	uint radial_segments = 32,
	uint height_segments = 1,
	bool capped = true
)
{
	return {
		.kind = PrimitiveKind.CYLINDER,
		.a = radius_top,
		.b = radius_bottom,
		.c = height,
		.u = primitive_segments(radial_segments, 3),
		.v = primitive_segments(height_segments, 1),
		.w = 1,
		.capped = capped,
	};
}

<*
 A torus in the XY plane — the ring around Z, Three.js's orientation.

 `tubular_segments` goes around the ring and `radial_segments` around the tube,
 which is the opposite of the order Three.js's *constructor* takes them in. The
 prelude keeps the constructor's order and swaps here.
*>
fn Primitive torus_shape(float radius, float tube, uint tubular_segments = 48, uint radial_segments = 12)
{
	return {
		.kind = PrimitiveKind.TORUS,
		.a = radius,
		.b = tube,
		.u = primitive_segments(tubular_segments, 3),
		.v = primitive_segments(radial_segments, 3),
		.w = 1,
	};
}

<*
 A segment count that cannot produce a degenerate mesh or exhaust the device.

 Both ends matter and for different reasons: below `least` the loops divide by
 zero or wind nothing, and above `MAX_PRIMITIVE_SEGMENTS` a mistyped literal
 becomes an allocation nobody meant to ask for.
*>
fn uint primitive_segments(uint requested, uint least)
{
	if (requested < least) return least;
	if (requested > MAX_PRIMITIVE_SEGMENTS) return MAX_PRIMITIVE_SEGMENTS;
	return requested;
}

<*
 The shape's identity: equal keys mean equal geometry.

 Readable rather than hashed, because it becomes `Asset.path` and a script that
 prints `mesh.geometry` or a stats dump should see
 `<box 2.000000x1.000000x2.000000 1x1x1>` and know what it is looking at. Every
 field that reaches a vertex is in it.
*>
fn String Primitive.key(&self, Allocator allocator)
{
	switch (self.kind)
	{
		case PrimitiveKind.BOX:
			return string::format(allocator, "<box %fx%fx%f %dx%dx%d>", self.a, self.b, self.c, self.u, self.v, self.w);
		case PrimitiveKind.SPHERE:
			return string::format(allocator, "<sphere r%f %dx%d>", self.a, self.u, self.v);
		case PrimitiveKind.PLANE:
			return string::format(allocator, "<plane %fx%f %dx%d>", self.a, self.b, self.u, self.v);
		case PrimitiveKind.CYLINDER:
			return string::format(
				allocator,
				"<cylinder %f/%f h%f %dx%d %s>",
				self.a,
				self.b,
				self.c,
				self.u,
				self.v,
				self.capped ? "capped" : "open"
			);
		case PrimitiveKind.TORUS:
			return string::format(allocator, "<torus r%f t%f %dx%d>", self.a, self.b, self.u, self.v);
		default:
			// Unreachable, and still total: a kind added above without a case here
			// gets a key that is wrongly *named* rather than one that collides with
			// another shape's, so the failure is a confusing path and not a mesh
			// that draws as something else.
			return string::format(
				allocator,
				"<%s %f/%f/%f %dx%dx%d %d>",
				self.kind.label(),
				self.a,
				self.b,
				self.c,
				self.u,
				self.v,
				self.w,
				self.capped ? 1 : 0
			);
	}
}

// ============================================================================
// Building
// ============================================================================

<*
 The three streams and the index list a shape is assembled into.

 Deliberately the same shape as what `upload_primitive` reads out of a glTF
 accessor, so both paths hand `upload_geometry` the same thing and there is one
 upload, one bounds computation and one BVH build for files and shapes alike.
*>
struct GeometryBuilder
{
	List{Vec3} positions;
	List{Vec3} normals;
	List{Vec2} uvs;
	// glTF's COLOR_0, and only ever filled by the path that re-reads a mesh out of
	// the file it came from — a generated shape has no colour attribute and a hull
	// never had one. Left empty by `vertex`, so a builder assembled shape by shape
	// has none.
	// 
	// Here rather than on the upload path because the reader is the exporter: a
	// layer whose mask reads a vertex colour needs the attribute written beside
	// it, or the mask it names is one the file does not carry.
	List{Vec4} colors;
	List{uint} indices;
}

<*
 Heap-backed from the first push: a List left with a null allocator resolves to
 `tmem`, and any `@pool()` up the stack then frees the vertices out from under
 the upload.
*>
fn void GeometryBuilder.init(&self)
{
	self.positions.init(mem, 256);
	self.normals.init(mem, 256);
	self.uvs.init(mem, 256);
	self.colors.init(mem, 0);
	self.indices.init(mem, 512);
}

fn void GeometryBuilder.free(&self)
{
	self.positions.free();
	self.normals.free();
	self.uvs.free();
	self.colors.free();
	self.indices.free();
}

<*
 @return `The new vertex's index, so a caller can wind triangles against it.`
*>
fn uint GeometryBuilder.vertex(&self, Vec3 position, Vec3 normal, Vec2 uv)
{
	uint at = (uint)self.positions.len();
	self.positions.push(position);
	self.normals.push(normal);
	self.uvs.push(uv);
	return at;
}

fn void GeometryBuilder.triangle(&self, uint a, uint b, uint c)
{
	self.indices.push(a);
	self.indices.push(b);
	self.indices.push(c);
}

fn void Primitive.build(&self, GeometryBuilder* out)
{
	switch (self.kind)
	{
		case PrimitiveKind.BOX: build_box(out, *self);
		case PrimitiveKind.SPHERE: build_sphere(out, *self);
		case PrimitiveKind.PLANE: build_plane(out, *self);
		case PrimitiveKind.CYLINDER: build_cylinder(out, *self);
		case PrimitiveKind.TORUS: build_torus(out, *self);
		default: break;
	}
}

<*
 A subdivided rectangle in an arbitrary frame — the one grid every flat surface
 here is made of, and six of them are a box.

 `u_axis × v_axis` must equal `normal`. That is the whole winding argument: with
 a right-handed frame, `(a, b, d)` and `(b, c, d)` over rows that run *down* the
 v axis come out counter-clockwise seen from +normal, which is the front face
 `render/pass.c3` keeps. A left-handed frame produces a face that is invisible
 from outside and visible from inside, and nothing about that reads as an error
 in a screenshot.

 @param offset : `How far along the normal the face sits — half the box's depth, or zero for a lone plane.`
*>
fn void build_face(
	GeometryBuilder* out,
	Vec3 u_axis,
	Vec3 v_axis,
	Vec3 normal,
	float u_length,
	float v_length,
	float offset,
	uint u_segments,
	uint v_segments
) @local
{
	uint first = (uint)out.positions.len();

	for (uint iv = 0; iv <= v_segments; iv++)
	{
		float fv = (float)iv / (float)v_segments;
		for (uint iu = 0; iu <= u_segments; iu++)
		{
			float fu      = (float)iu / (float)u_segments;
			Vec3 position = u_axis * ((fu - 0.5f) * u_length) + v_axis * ((0.5f - fv) * v_length) + normal * offset;
			// v counts down the face and the texture coordinate counts up, which is
			// Three.js's layout: uv (0, 0) is the bottom-left corner.
			out.vertex(position, normal, { fu, 1.0f - fv });
		}
	}

	uint stride = u_segments + 1;
	for (uint iv = 0; iv < v_segments; iv++)
	{
		for (uint iu = 0; iu < u_segments; iu++)
		{
			uint a = first + iv * stride + iu;
			uint b = a + stride;
			uint c = b + 1;
			uint d = a + 1;
			out.triangle(a, b, d);
			out.triangle(b, c, d);
		}
	}
}

<*
 Six faces, in Three.js's order: +X, -X, +Y, -Y, +Z, -Z.

 Each is a `build_face` whose frame is right-handed about its own outward normal,
 and the segment counts follow Three.js's — the +X face is subdivided by (depth,
 height) rather than by (width, height), because those are the axes it spans.
*>
fn void build_box(GeometryBuilder* out, Primitive shape) @local
{
	float half_width  = shape.a * 0.5f;
	float half_height = shape.b * 0.5f;
	float half_depth  = shape.c * 0.5f;

	build_face(out, { 0, 0, -1 }, { 0, 1, 0 }, { 1, 0, 0 }, shape.c, shape.b, half_width, shape.w, shape.v);
	build_face(out, { 0, 0, 1 }, { 0, 1, 0 }, { -1, 0, 0 }, shape.c, shape.b, half_width, shape.w, shape.v);
	build_face(out, { 1, 0, 0 }, { 0, 0, -1 }, { 0, 1, 0 }, shape.a, shape.c, half_height, shape.u, shape.w);
	build_face(out, { 1, 0, 0 }, { 0, 0, 1 }, { 0, -1, 0 }, shape.a, shape.c, half_height, shape.u, shape.w);
	build_face(out, { 1, 0, 0 }, { 0, 1, 0 }, { 0, 0, 1 }, shape.a, shape.b, half_depth, shape.u, shape.v);
	build_face(out, { -1, 0, 0 }, { 0, 1, 0 }, { 0, 0, -1 }, shape.a, shape.b, half_depth, shape.u, shape.v);
}

fn void build_plane(GeometryBuilder* out, Primitive shape) @local
{
	build_face(out, { 1, 0, 0 }, { 0, 1, 0 }, { 0, 0, 1 }, shape.a, shape.b, 0, shape.u, shape.v);
}

<*
 A UV sphere: rings of longitude from the north pole down.

 The ring nearest each pole is a fan of triangles rather than a grid of quads,
 because the quad's two upper vertices are the same point — so one of its two
 triangles is degenerate. Emitting it anyway would put zero-area triangles in the
 BVH, where they are a ray test that can never hit and a leaf that can never be
 pruned.
*>
fn void build_sphere(GeometryBuilder* out, Primitive shape) @local
{
	float radius         = shape.a;
	uint width_segments  = shape.u;
	uint height_segments = shape.v;
	uint first           = (uint)out.positions.len();

	for (uint iy = 0; iy <= height_segments; iy++)
	{
		float v     = (float)iy / (float)height_segments;
		float theta = v * (float)math::PI;
		for (uint ix = 0; ix <= width_segments; ix++)
		{
			float u   = (float)ix / (float)width_segments;
			float phi = u * (float)math::TAU;
			Vec3 position = {
				-radius * math::cos(phi) * math::sin(theta),
				radius * math::cos(theta),
				radius * math::sin(phi) * math::sin(theta),
			};
			// From the centre, which is what a sphere's normal is — and it stays
			// unit length under the normalize even at the poles, where the two sines
			// vanish and only the cosine survives.
			out.vertex(position, position.normalize(), { u, 1.0f - v });
		}
	}

	uint stride = width_segments + 1;
	for (uint iy = 0; iy < height_segments; iy++)
	{
		for (uint ix = 0; ix < width_segments; ix++)
		{
			uint a = first + iy * stride + ix + 1;
			uint b = first + iy * stride + ix;
			uint c = first + (iy + 1) * stride + ix;
			uint d = first + (iy + 1) * stride + ix + 1;
			if (iy != 0) out.triangle(a, b, d);
			if (iy != height_segments - 1) out.triangle(b, c, d);
		}
	}
}

<*
 The side wall, then the two flat ends.

 The side's normal is not radial: it leans by the slope of the wall, so a cone is
 lit as a cone rather than as a cylinder that happens to taper. Getting this
 wrong is the classic silent one — the silhouette is right and only the shading
 says otherwise.
*>
fn void build_cylinder(GeometryBuilder* out, Primitive shape) @local
{
	float radius_top    = shape.a;
	float radius_bottom = shape.b;
	float height        = shape.c;
	uint radial         = shape.u;
	uint rows           = shape.v;

	float half  = height * 0.5f;
	float slope = (radius_bottom - radius_top) / height;
	uint first  = (uint)out.positions.len();

	for (uint iy = 0; iy <= rows; iy++)
	{
		float v      = (float)iy / (float)rows;
		float radius = v * (radius_bottom - radius_top) + radius_top;
		for (uint ix = 0; ix <= radial; ix++)
		{
			float u         = (float)ix / (float)radial;
			float theta     = u * (float)math::TAU;
			float sin_theta = math::sin(theta);
			float cos_theta = math::cos(theta);
			Vec3 normal     = ((Vec3) { sin_theta, slope, cos_theta }).normalize();
			out.vertex({ radius * sin_theta, half - v * height, radius * cos_theta }, normal, { u, 1.0f - v });
		}
	}

	uint stride = radial + 1;
	for (uint iy = 0; iy < rows; iy++)
	{
		for (uint ix = 0; ix < radial; ix++)
		{
			uint a = first + iy * stride + ix;
			uint b = a + stride;
			uint c = b + 1;
			uint d = a + 1;
			// A tip is a row of points, not a row of edges: the half of each quad
			// that collapses onto it is dropped, as at a sphere's pole.
			if (radius_top > 0 || iy != 0) out.triangle(a, b, d);
			if (radius_bottom > 0 || iy != rows - 1) out.triangle(b, c, d);
		}
	}

	if (shape.capped)
	{
		if (radius_top > 0) build_cap(out, radius_top, half, true, radial);
		if (radius_bottom > 0) build_cap(out, radius_bottom, -half, false, radial);
	}
}

<*
 One flat end, as a fan around a single centre vertex.

 Three.js pushes a *copy* of the centre per segment; every copy carries the same
 position, normal and uv, so the copies exist only to keep each triangle's three
 vertices adjacent in the buffer for its group bookkeeping. There are no groups
 here, so there is one centre.
*>
fn void build_cap(GeometryBuilder* out, float radius, float y, bool top, uint radial) @local
{
	float sign  = top ? 1.0f : -1.0f;
	Vec3 normal = { 0, sign, 0 };

	uint centre = out.vertex({ 0, y, 0 }, normal, { 0.5f, 0.5f });
	uint first  = (uint)out.positions.len();

	for (uint ix = 0; ix <= radial; ix++)
	{
		float theta     = (float)ix / (float)radial * (float)math::TAU;
		float sin_theta = math::sin(theta);
		float cos_theta = math::cos(theta);
		// The uv is the disc seen from outside, so the bottom cap's mirrors the
		// top's — otherwise a texture reads backwards on one of the two.
		out.vertex(
			{ radius * sin_theta, y, radius * cos_theta },
			normal,
			{ cos_theta * 0.5f + 0.5f, sin_theta * 0.5f * sign + 0.5f },
		);
	}

	for (uint ix = 0; ix < radial; ix++)
	{
		uint i = first + ix;
		if (top)
		{
			out.triangle(i, i + 1, centre);
		}
		else
		{
			out.triangle(i + 1, i, centre);
		}
	}
}

<*
 A torus in the XY plane: the tube swept around the Z axis.

 `u` runs around the ring and `v` around the tube, and the normal is the vertex
 minus the point on the ring's centre line beneath it — which is exact, so there
 is no accumulated error to notice at high tessellation.
*>
fn void build_torus(GeometryBuilder* out, Primitive shape) @local
{
	float radius = shape.a;
	float tube   = shape.b;
	uint tubular = shape.u;
	uint radial  = shape.v;
	uint first   = (uint)out.positions.len();

	for (uint j = 0; j <= radial; j++)
	{
		float v = (float)j / (float)radial * (float)math::TAU;
		for (uint i = 0; i <= tubular; i++)
		{
			float u       = (float)i / (float)tubular * (float)math::TAU;
			float ring    = radius + tube * math::cos(v);
			Vec3 position = { ring * math::cos(u), ring * math::sin(u), tube * math::sin(v) };
			Vec3 centre   = { radius * math::cos(u), radius * math::sin(u), 0 };
			out.vertex(
				position,
				(position - centre).normalize(),
				{
					(float)i / (float)tubular,
					(float)j / (float)radial,
				}
			);
		}
	}

	uint stride = tubular + 1;
	for (uint j = 1; j <= radial; j++)
	{
		for (uint i = 1; i <= tubular; i++)
		{
			uint a = first + stride * j + i - 1;
			uint b = first + stride * (j - 1) + i - 1;
			uint c = first + stride * (j - 1) + i;
			uint d = first + stride * j + i;
			out.triangle(a, b, d);
			out.triangle(b, c, d);
		}
	}
}

// ============================================================================
// Uploading
// ============================================================================

<*
 Builds a shape and uploads it, or answers with the one already built for exactly
 these numbers.

 Keyed on `Asset.path`, which a generated shape fills in with `Primitive.key` the
 way a loaded file fills it in with its filename, so the two kinds of asset share
 one table and one dedup rule.

 @return `The asset's handle, for Scene.add_mesh.`
 @return ? PRIMITIVE_HAS_NO_TRIANGLES : `The numbers describe nothing — a zero radius, a zero-height cone with no caps. The prelude refuses these first; this is what a forged __three.primitive call gets.`
*>
fn AssetId? Assets.primitive(&self, Gpu* gpu, Primitive shape)
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

		if (geometry.indices.len() < 3 || geometry.positions.len() == 0) return PRIMITIVE_HAS_NO_TRIANGLES~;

		AssetId built = self.upload_built(gpu, key, shape.kind.label(), &geometry)!;
		// Kept so the exporter can tessellate this again rather than read it back
		// off the device. Set after the upload rather than through `upload_built`,
		// which builds hulls and glTF primitives too and has no business knowing
		// what a parametric shape is.
		self.slot(built).primitive = shape;
		self.slot(built).has_primitive = true;
		return built;
	};
}

<*
 The asset already built under this key, if there is one.

 Split out because it is the *first* half of the dedup rule and every generator
 needs it before it does the work: `Assets.primitive` asks before it tessellates
 and `Assets.convex` asks before it runs a hull, which keeps a repeated
 construction cheap rather than merely deduplicated after the fact.

 @return ? NOTHING_BUILT_UNDER_THAT_KEY : `No generator has filed an asset under this key yet.`
*>
fn AssetId? Assets.built(&self, String key)
{
	foreach (i, &existing : self.assets)
	{
		// Liveness first, for `Assets.load`'s reason: a swept slot keeps its key
		// until something overwrites it, and matching on one would hand back an
		// asset that is no longer there.
		if (existing.alive && existing.path == key)
		{
			return { .index = (uint)i, .generation = existing.generation };
		}
	}
	return NOTHING_BUILT_UNDER_THAT_KEY~;
}

<*
 Uploads a filled `GeometryBuilder` as a one-mesh asset filed under `key`.

 The tail every generator shares — the upload, the bounds, the BVH and the
 all-or-nothing cleanup — so a shape three.c3 tessellated, a hull it computed and
 a glTF primitive it read all reach the device through one piece of code and are
 indistinguishable afterwards.

 The optional streams are optional by length rather than by flag. A builder that
 filled `normals` and `uvs` for every position gets both uploaded; one that left
 `uvs` empty — a convex hull, which has no natural parameterisation — gets
 `has_uvs = false` and the shader's no-uv branch. That is the same test
 `upload_primitive` applies to a glTF accessor.

 `key` and `label` are copied; the caller may hand over temporary strings.

 @param key : `What Asset.path becomes: the shape's identity, and what Assets.built matches on.`
 @param label : `What GpuMesh.name becomes, for asset.meshes and stats dumps.`
 @param lines : `True when the indices are pairs for PRIMITIVE_TOPOLOGY_LINE_LIST rather than triangles. Skips the picking tree, which would read them three at a time.`
 @return `The new asset's handle, for Scene.add_mesh.`
*>
fn AssetId? Assets.upload_built(
	&self,
	Gpu* gpu,
	String key,
	String label,
	GeometryBuilder* geometry,
	bool lines = false
)
{
	// The generated streams sample the white stand-in, exactly as an untextured
	// glTF primitive does: the binding is pushed for every draw whether or not the
	// mesh carries uvs, so it has to be occupied either way.
	self.ensure_white(gpu)!;

	GpuMesh mesh = {
		.name = label.copy(mem),
		.vertex_count = (uint)geometry.positions.len(),
		.index_count = (uint)geometry.indices.len(),
		.has_normals = geometry.normals.len() == geometry.positions.len(),
		.has_uvs = geometry.uvs.len() == geometry.positions.len(),
		// The same optional-by-length test as the two above. Nothing three.c3
		// tessellates fills this — a box has no colour attribute and a hull never
		// had one — but a mesh handed in from outside does, and the exporter's
		// re-read path fills it for a mesh that came out of a file carrying one.
		.has_colors = geometry.colors.len() == geometry.positions.len(),
		.base_color = srgb_to_linear_rgb(PRIMITIVE_COLOR),
		.texture = -1,
		.bounds = bounds_of(geometry.positions.array_view()),
	};

	Asset asset = { .path = key.copy(mem) };
	asset.meshes.init(mem, 1);
	asset.bounds = mesh.bounds;

	// Nothing below is on `self.assets` yet, so a failure part-way is this scope's
	// to undo — the same argument `Assets.load` makes.
	defer catch
	{
		mesh.free_buffers(gpu);
		asset.meshes.free();
		asset.path.free(mem);
	}

	mesh.positions = gpu.upload_stream(geometry.positions.entries, Vec3::size * geometry.positions.len())!;
	if (mesh.has_normals)
	{
		mesh.normals = gpu.upload_stream(geometry.normals.entries, Vec3::size * geometry.normals.len())!;
	}
	if (mesh.has_uvs)
	{
		mesh.uvs = gpu.upload_stream(geometry.uvs.entries, Vec2::size * geometry.uvs.len())!;
	}
	if (mesh.has_colors)
	{
		mesh.colors = gpu.upload_stream(geometry.colors.entries, Vec4::size * geometry.colors.len())!;
	}
	mesh.indices = gpu.upload_indices(geometry.indices.entries, uint::size * geometry.indices.len())!;
	// Not for lines. The index buffer is pairs and `build_bvh` reads it in threes,
	// so a line mesh would get a tree over triangles that do not exist and
	// `scene.pick` would answer with a hit on a debug helper. Skipping it is also
	// what makes a helper unpickable — `pick.c3` steps over a mesh with no tree —
	// and that is what a script wants: a click goes through the box helper onto
	// the thing it is drawn around.
	if (!lines) mesh.build_bvh(geometry.positions.array_view(), geometry.indices.array_view());

	// A generated shape has no file to go back to, so it is uploaded at the moment
	// it is built and says so — `ensure_uploaded` would have nothing to read from
	// if it were ever reached for one.
	mesh.uploaded = true;
	mesh.gltf_mesh = -1;
	mesh.gltf_primitive = -1;
	asset.meshes.push(mesh);
	return self.claim_slot(asset);
}

<*
 The tight box around a generated shape.

 Computed from the vertices rather than from the parameters, so it is right for a
 shape whose extent is not obvious from its numbers — a torus is `radius + tube`
 wide and `tube` deep, and a cone's box is not centred on its own origin in the
 way a first guess suggests.
*>
fn collision::Aabb3 bounds_of(Vec3[] positions)
{
	if (positions.len == 0) return { };

	collision::Aabb3 box = { .min = positions[0], .max = positions[0] };
	foreach (position : positions) box.expand_by_point(position);
	return box;
}