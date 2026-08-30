<*
 The convex hull of a point cloud — Three.js's `ConvexGeometry`, and the one
 geometry whose parameter is an array.

 A point cloud is a *description*, not vertices. Most of the points are thrown
 away — a cloud of 500 inside a cube produces eight vertices — and which survive
 is quickhull's business. Nothing is read back, nothing is written after the
 fact, and the result is an asset handle exactly like `three.load` or
 `new three.BoxGeometry(1, 1, 1)` returns: one upload per distinct cloud, N
 transforms, one instanced draw. This is not `BufferGeometry` — there is still
 no way to hand over triangles, bind an attribute, or ask an asset what it is
 made of.

 What it buys is the shape nothing else can express: rocks, crystals, gems,
 debris, low-poly terrain blocks, the convex bound of a scanned cloud.

 ## Flat, because a hull is flat

 One vertex per face corner carrying that face's normal, as Three.js does. A
 convex hull's faces meet at hard creases, and averaging a normal across them
 rounds off the one feature that makes a hull look like a cut stone. The cost is
 unshared vertices — a 60-point cloud is roughly 116 triangles and 348 vertices
 — paid once at upload.

 ## The uvs are a projection, not an unwrap

 There is no unwrap of an arbitrary hull that does not visibly seam. Every face
 instead gets its own planar projection along its own normal, in local space:

 t = normalize(cross(axis, n))     axis is whichever of x/y/z is least like n
 b = cross(n, t)
 uv = (dot(p, t), dot(p, b))

 One unit of uv is one unit of local space on every face, so a texture is the
 same size everywhere on the hull and the same size on a hull as on a box beside
 it. Nothing is normalised into 0..1 — a `_REPEAT` sampler makes that sensible,
 and squeezing a whole rock into one tile would tie texel density to how big the
 rock is.

 The rule is one an agent can hold: the picture is applied to each facet
 face-on. It never stretches, since the basis is orthonormal and the face flat,
 and the only artefact is that two faces meeting at a crease do not agree along
 the shared edge — visible on a repeating material, invisible on the noise,
 grain and speckle a rock actually wants. (Triplanar in the shader is the same
 projection with a three-way blend on top, and costs every mesh in the project a
 shader branch.)

 It is deterministic: the basis comes from the normal alone by a fixed rule, so
 re-running quickhull on the same cloud gives the same uvs, and because the
 projection is of the *position* rather than a corner index, two coplanar faces
 tile continuously across the edge between them instead of seaming in the middle
 of a flat wall.

 ## The winding is enforced, not assumed

 `collision::quickhull` documents an outward-facing result, and `orient_outward`
 checks it anyway, per face, against the hull's own centroid. Under
 `CULL_MODE_BACK_BIT` an inverted face is not a dark patch — it is a hole you can
 see the inside of the rock through. The normal has to be computed per face for
 the flat shading regardless, so checking its sign is free.

 ## The key is a hash

 `Primitive.key` spells its parameters out, but 500 points spelled out is a 12 KB
 `Asset.path`, so the key is `<convex n=500 h=...>`: the point count and a 64-bit
 FNV-1a over every coordinate's bits.

 - Bit-exact, where `Primitive.key` is exact to six decimals. Two clouds
 differing in the last bit of one coordinate are different assets. That is the
 right way round: a size is typed by hand, a cloud comes out of a loop, and the
 same loop gives the same bits.
 - Two different clouds with the same hull are two assets. Deduping on the hull
 would need the hull computed before the lookup, which is the expensive half;
 keying on the input keeps the case that actually happens — the same array
 handed over twice — free.
*>
module three;

import std::math;
import std::math::vector;
import collision;

faultdef CONVEX_HULL_IS_DEGENERATE, TOO_MANY_CONVEX_POINTS;

<*
 Beyond this many points a hull is a stall rather than a shape.

 quickhull is near-linear on the clouds people actually build and quadratic in
 the adversarial case, so the cap keeps a mistyped loop bound from turning
 `run_script` into something that never answers. Sixty-five thousand is far
 above the hundred-odd points the Three.js example uses and still above a
 decimated scan.

 `prelude.js` refuses anything larger with a sentence naming the cap; this is
 the backstop for a script calling `__three.convex` itself.
*>
const uint MAX_CONVEX_POINTS = 65536;

<*
 The fewest points that can enclose a volume. Fewer is a plane, a line or a
 point, and quickhull answers with an empty mesh for all three.
*>
const uint MIN_CONVEX_POINTS = 4;

<*
 A face smaller than this is not a face.

 quickhull can emit a zero-area triangle where an input point lands exactly on an
 edge of the finished hull, and keeps them because a closed surface is what a
 collision volume needs. A renderable mesh wants the opposite: a triangle with no
 area has no normal to shade it with, divides by zero on the way to one, covers
 no pixels, and is one more BVH leaf no ray can hit.

 Compared against twice the triangle's area — the length of the un-normalised
 cross product — because that is the quantity already in hand.
*>
const float CONVEX_MIN_FACE_AREA2 = 1e-12f;

<*
 The identity of a point cloud: equal keys mean equal input.

 Hashed per component rather than over the array's memory. `Vec3` is
 `float[<3>]`, a vector type whose alignment exceeds its extent, so hashing raw
 bytes would fold in padding nothing ever wrote.
*>
fn String convex_key(Vec3[] points, Allocator allocator)
{
	// FNV-1a, 64-bit. Not cryptographic and does not need to be — it only has to
	// not collide by accident, and a collision needs two different clouds of the
	// *same point count* landing on the same 64 bits.
	ulong hash = 0xcbf29ce484222325;
	foreach (point : points)
	{
		for (usz axis = 0; axis < 3; axis++)
		{
			uint bits = bitcast(point[axis], uint);
			for (usz byte = 0; byte < 4; byte++)
			{
				hash ^= (ulong)((bits >> (uint)(byte * 8)) & 0xff);
				hash *= 0x100000001b3;
			}
		}
	}
	return string::format(allocator, "<convex n=%d h=%x>", points.len, hash);
}

<*
 Two unit vectors perpendicular to `normal` and to each other.

 The seed axis is whichever of x, y and z the normal is *least* aligned with,
 which keeps the cross product away from zero: a normal parallel to the axis
 gives a tangent of length nothing and a uv of NaN, and a hull has faces pointing
 every way by construction.

 Fixed rather than arbitrary. The same normal always produces the same pair, so
 two coplanar faces get the same basis and their projections line up across the
 edge between them.

 @require normal.length() > 0.99 && normal.length() < 1.01 : `must already be unit`
 @param [out] tangent : `Unit, perpendicular to normal.`
 @param [out] bitangent : `Unit, perpendicular to both, completing a right-handed frame with normal.`
*>
fn void face_basis(Vec3 normal, Vec3* tangent, Vec3* bitangent)
{
	float ax  = math::abs(normal.x);
	float ay  = math::abs(normal.y);
	float az  = math::abs(normal.z);
	Vec3 axis = { 1, 0, 0 };
	if (az <= ax && az <= ay)
	{
		axis = { 0, 0, 1 };
	}
	else if (ay <= ax)
	{
		axis = { 0, 1, 0 };
	}

	Vec3 t = axis.cross(normal).normalize();
	*tangent = t;
	// A cross of two unit perpendicular vectors is already unit; normalising it
	// again would be arithmetic with nothing to fix.
	*bitangent = normal.cross(t);
}

<*
 Fills `out` with the flat-shaded surface of the convex hull of `points`.

 Left empty when the cloud encloses no volume — fewer than four points, or points
 that are all equal, collinear or coplanar. The caller reports that.
*>
fn void build_convex(GeometryBuilder* out, Vec3[] points)
{
	if (points.len < MIN_CONVEX_POINTS) return;

	collision::Mesh hull = collision::quickhull(points);
	defer hull.free();
	if (hull.triangles.len() == 0) return;

	// Strictly inside the hull, because a convex body contains the average of
	// its own vertices — which makes it a usable reference for "which way is
	// out" at every face at once.
	Vec3 inside = { 0, 0, 0 };
	foreach (vertex : hull.vertices) inside += vertex;
	inside = inside / (float)hull.vertices.len();

	foreach (triangle : hull.triangles)
	{
		Vec3 a = hull.vertices[triangle[0]];
		Vec3 b = hull.vertices[triangle[1]];
		Vec3 c = hull.vertices[triangle[2]];

		Vec3 cross  = (b - a).cross(c - a);
		float area2 = cross.length();
		if (area2 < CONVEX_MIN_FACE_AREA2) continue;

		Vec3 normal = cross / area2;
		if (normal.dot((a + b + c) / 3.0f - inside) < 0)
		{
			// Wound the wrong way round. Swapping two corners flips the winding
			// and the normal together, which is the only fix that leaves the two
			// agreeing.
			Vec3 swap = b;
			b = c;
			c = swap;
			normal = -normal;
		}

		// One vertex per corner per face: flat shading, and the crease between
		// two faces stays a crease. The uvs are this face's own planar
		// projection — see the header.
		Vec3 tangent;
		Vec3 bitangent;
		face_basis(normal, &tangent, &bitangent);

		uint first      = (uint)out.positions.len();
		Vec3[3] corners = { a, b, c };
		foreach (corner : corners)
		{
			out.positions.push(corner);
			out.normals.push(normal);
			out.uvs.push({ corner.dot(tangent), corner.dot(bitangent) });
		}
		out.triangle(first, first + 1, first + 2);
	}
}

<*
 Computes the convex hull of `points` and uploads it, or answers with the asset
 already built for exactly this cloud.

 The dedup is `Assets.primitive`'s, against `convex_key`, and it is checked
 *before* the hull runs: handing the same array over twice costs one lookup the
 second time, not a second quickhull.

 @param points : `The cloud, in the mesh's own local space. Not modified, and not retained.`
 @return `The asset's handle, for Scene.add_mesh.`
 @return ? TOO_MANY_CONVEX_POINTS : `More than MAX_CONVEX_POINTS. The prelude refuses these first; this is what a forged __three.convex call gets.`
 @return ? CONVEX_HULL_IS_DEGENERATE : `The cloud encloses no volume — fewer than four points, or points that are all equal, collinear or coplanar.`
*>
fn AssetId? Assets.convex(&self, Gpu* gpu, Vec3[] points)
{
	if (!self.started) self.init();
	if (points.len > MAX_CONVEX_POINTS) return TOO_MANY_CONVEX_POINTS~;

	@pool()
	{
		String key = convex_key(points, tmem);
		if (try hit = self.built(key)) return hit;

		GeometryBuilder geometry;
		geometry.init();
		defer geometry.free();
		build_convex(&geometry, points);

		if (geometry.indices.len() < 3) return CONVEX_HULL_IS_DEGENERATE~;

		return self.upload_built(gpu, key, "convex", &geometry);
	};
}