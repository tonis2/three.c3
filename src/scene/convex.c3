<*
 The convex hull of a point cloud — Three.js's `ConvexGeometry`, and the one
 shape whose parameter is an array.

 ## Why an array of points does not spend the thesis

 `plan.md`'s rule is that **an instance is an immutable asset reference plus a
 transform, and JS may not touch vertices**, and `scene/primitive.c3` argues that
 `BoxGeometry` leaves it standing because what crosses is a shape's *name and its
 numbers*. This file crosses something larger — a cloud of points — and the rule
 still holds, because the rule was never about the size of the argument. It is
 about four things, and a hull keeps all four:

 - **Nothing is read back.** There is no accessor from a `ConvexGeometry` to a
   position, a normal or an index. What comes back is an asset index, the same
   one `three.load` and `new three.BoxGeometry(1, 1, 1)` hand over.
 - **Nothing is written after the fact.** The asset is immutable from the
   instant it exists; a script that wants a different hull constructs a
   different geometry, exactly as it would a different box.
 - **The points are not the vertices.** They are a *description* that a hull is
   computed from. Most of them are thrown away — a cloud of 500 points inside a
   cube produces eight vertices — and which ones survive is quickhull's business
   and not the script's.
 - **The scene stays optimized by construction.** One upload per distinct cloud,
   deduped like every other asset, N transforms, one instanced draw.

 What it is *not* is `BufferGeometry`. There is still no way to hand over
 triangles, no attribute to bind, no index buffer to fill, and no way to ask an
 asset what it is made of. A point cloud is the widest input this API takes and
 it is still a description; the refusal that made every expressible scene fast is
 where it was.

 What it buys is the shape an agent cannot otherwise express. Rocks, crystals,
 gems, chunks of debris, low-poly terrain blocks, the convex bound of a scanned
 cloud — none of those are a box, a sphere or a torus, and before this the only
 way to get one was a `.glb` somebody had already made.

 ## Flat, because a hull is flat

 Three.js's `ConvexGeometry` emits one vertex per face corner carrying that
 face's normal, and no uvs at all. Both are copied, and both are right rather
 than merely compatible: a convex hull's faces meet at hard creases, and
 averaging a normal across them rounds off the one feature that makes a hull look
 like a cut stone. The cost is that vertices are not shared between faces —
 a 60-point cloud is roughly 116 triangles and 348 vertices instead of 60 — which
 is the trade Three.js makes too, and it is paid once at upload.

 ## The uvs are a projection, not an unwrap

 There is no unwrap of an arbitrary hull that does not visibly seam — that is
 still true, and it is why this is not one. Every face gets its own **planar
 projection along its own normal**, taken in the mesh's local space:

 	t = normalize(cross(axis, n))     axis is whichever of x/y/z is least like n
 	b = cross(n, t)
 	uv = (dot(p, t), dot(p, b))

 One unit of uv is one unit of local space on every face, so a texture is the
 same size everywhere on the hull and the same size on a hull as on a box beside
 it. Nothing is normalised into 0..1: a `_REPEAT` sampler is what makes that
 sensible, and squeezing a whole rock into one tile would make the texel density
 depend on how big the rock is.

 **Why this is honest where a fabricated unwrap would not be.** A projection has
 a rule an agent can hold: the picture is applied to each facet face-on. It never
 stretches — the basis is orthonormal and the face is flat, so the mapping is an
 isometry rather than a projection *of* anything — and the only artefact is that
 two faces meeting at a crease do not agree along the shared edge. That is
 visible on a repeating material and invisible on the noise, grain and speckle
 that a rock, a crystal or a chunk of debris actually wants, which is the case
 `plan.md` §2 named. The alternative it names, triplanar in the shader, is the
 same projection with a three-way blend on top and costs every mesh in the
 project a shader branch to give a hull a softer crease.

 **Deterministic, and stable under the one thing that would show.** The basis is
 derived from the normal alone by a fixed rule, so re-running quickhull on the
 same cloud produces the same uvs; and because the projection is of the *position*
 rather than of a corner index, two coplanar faces — which a hull produces
 whenever four points are flush — tile continuously across the edge between them
 instead of showing a seam in the middle of a flat wall.

 The gable ends in `plan.md` §2 are exactly that case: hull prisms next to a
 textured roof, flat-coloured before this because the stream was empty.

 ## The winding is enforced here, not assumed

 `collision::quickhull` documents an outward-facing result, and this file checks
 it anyway, per face, against the hull's own centroid. That is three lines
 (`orient_outward`) and it buys the invariant that `render/pass.c3` actually
 depends on: under `CULL_MODE_BACK_BIT` an inverted face is not a dark patch, it
 is a hole you can see the inside of the rock through. Since the normal has to be
 computed per face for the flat shading regardless, checking its sign is free —
 and a hull whose winding convention changed under us would otherwise fail as a
 rendering bug in somebody's scene rather than as a test here.

 ## The key is a hash, which is the one place this differs from a primitive

 `Primitive.key` spells its parameters out, so `<box 2.000000x1.000000x2.000000 1x1x1>`
 is a path a stats dump can print. A cloud cannot do that — 500 points spelled
 out is a 12 KB `Asset.path` — so the key is `<convex n=500 h=...>`: the point
 count and a 64-bit FNV-1a over every coordinate's bits.

 Two consequences worth stating:

 - **It is bit-exact, where `Primitive.key` is exact to six decimals.** A box
   1.0 wide and one 1.0000001 wide are the same asset; two clouds differing in
   the last bit of one coordinate are not. That is the right way round for what
   each actually is: a size is usually typed by hand and a cloud is always
   produced by a loop, and the same loop gives the same bits.
 - **Two different clouds with the same hull are two assets.** Deduping on the
   hull instead would need the hull computed before the lookup, which is the
   expensive half; keying on the input keeps the repeated construction an agent
   writes — the same array handed over twice — free, which is the case that
   happens.
*>
module three;

import std::math;
import std::math::vector;
import collision;

faultdef CONVEX_HULL_IS_DEGENERATE, TOO_MANY_CONVEX_POINTS;

<*
 Beyond this many points a hull is a stall rather than a shape.

 quickhull is near-linear on the clouds people actually build and quadratic in
 the adversarial case, so the cap is what keeps a mistyped loop bound from
 turning `run_script` into something that never answers. Sixty-five thousand is
 far above the hundred-odd points the Three.js example uses and still above a
 decimated scan, which are the two real workloads.

 `prelude.js` refuses anything larger with a sentence naming the cap, so an agent
 is told; this is the backstop for a script that calls `__three.convex` itself.
*>
const uint MAX_CONVEX_POINTS = 65536;

<*
 The fewest points that can enclose a volume. Fewer is a plane, a line or a
 point, and quickhull answers with an empty mesh for all three.
*>
const uint MIN_CONVEX_POINTS = 4;

<*
 A face smaller than this is not a face.

 quickhull can emit a zero-area triangle where an input point lands exactly on
 an edge of the finished hull, and says so — it keeps them because a closed
 surface is what a collision volume needs. A *renderable* mesh wants the
 opposite: a triangle with no area has no normal to shade it with, would divide
 by zero on the way to one, and covers no pixels, so the hole left by dropping it
 is a hole of zero size. It is also one more leaf in the BVH that no ray can
 ever hit.

 Compared against twice the triangle's area — the length of the un-normalised
 cross product — because that is the quantity already in hand.
*>
const float CONVEX_MIN_FACE_AREA2 = 1e-12f;

<*
 The identity of a point cloud: equal keys mean equal input.

 Hashed per component rather than over the array's memory, which is not the same
 thing and is the difference between a stable key and a random one: `Vec3` is
 `float[<3>]`, a vector type whose alignment exceeds its extent, so hashing raw
 bytes would fold in padding that nothing ever wrote.
*>
fn String convex_key(Vec3[] points, Allocator allocator)
{
	// FNV-1a, 64-bit. Not a cryptographic hash and does not need to be — the
	// only thing it has to do is not collide by accident, and a collision needs
	// two different clouds of *the same point count* landing on the same 64 bits.
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
 which is what keeps the cross product away from zero: a normal parallel to the
 axis would give a tangent of length nothing and a uv of NaN, and a hull has faces
 pointing every way by construction, so the degenerate case is not hypothetical.

 Fixed rather than arbitrary. The same normal always produces the same pair, so
 two coplanar faces — which a hull produces whenever four of the cloud's points
 are flush — get the same basis and their projections line up across the edge
 between them.

 @require normal.length() > 0.99 && normal.length() < 1.01 : `must already be unit`
 @param [out] tangent : `Unit, perpendicular to normal.`
 @param [out] bitangent : `Unit, perpendicular to both, completing a right-handed frame with normal.`
*>
fn void face_basis(Vec3 normal, Vec3* tangent, Vec3* bitangent)
{
	float ax = math::abs(normal.x);
	float ay = math::abs(normal.y);
	float az = math::abs(normal.z);
	Vec3 axis = { 1, 0, 0 };
	if (az <= ax && az <= ay) { axis = { 0, 0, 1 }; }
	else if (ay <= ax) { axis = { 0, 1, 0 }; }

	Vec3 t = axis.cross(normal).normalize();
	*tangent = t;
	// A cross of two unit perpendicular vectors is already unit; normalising it
	// again would be arithmetic with nothing to fix.
	*bitangent = normal.cross(t);
}

<*
 Fill `out` with the flat-shaded surface of the convex hull of `points`.

 Left empty when the cloud encloses no volume — fewer than four points, or
 points that are all equal, collinear or coplanar. The caller reports that;
 there is nothing this function can say about it that the caller cannot say
 better.
*>
fn void build_convex(GeometryBuilder* out, Vec3[] points)
{
	if (points.len < MIN_CONVEX_POINTS) return;

	collision::Mesh hull = collision::quickhull(points);
	defer hull.free();
	if (hull.triangles.len() == 0) return;

	// Strictly inside the hull, because a convex body contains the average of
	// its own vertices. That is what makes it a usable reference for "which way
	// is out" at every face at once — see the header.
	Vec3 inside = { 0, 0, 0 };
	foreach (vertex : hull.vertices) inside += vertex;
	inside = inside / (float)hull.vertices.len();

	foreach (triangle : hull.triangles)
	{
		Vec3 a = hull.vertices[triangle[0]];
		Vec3 b = hull.vertices[triangle[1]];
		Vec3 c = hull.vertices[triangle[2]];

		Vec3 cross = (b - a).cross(c - a);
		float area2 = cross.length();
		if (area2 < CONVEX_MIN_FACE_AREA2) continue;

		Vec3 normal = cross / area2;
		if (normal.dot((a + b + c) / 3.0f - inside) < 0)
		{
			// Wound the wrong way round. Swapping two corners flips the winding
			// and the normal together, which is the only way to fix it that
			// leaves the two agreeing.
			Vec3 swap = b;
			b = c;
			c = swap;
			normal = -normal;
		}

		// One vertex per corner per face: flat shading, and the crease between
		// two faces stays a crease. The uvs are this face's own planar
		// projection — the header has the rule and the reason it is a projection
		// rather than an unwrap.
		Vec3 tangent;
		Vec3 bitangent;
		face_basis(normal, &tangent, &bitangent);

		uint first = (uint)out.positions.len();
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
 Compute the convex hull of `points` and upload it — or answer with the asset
 already built for exactly this cloud.

 The dedup is `Assets.primitive`'s, against `convex_key` rather than
 `Primitive.key`, and it is checked *before* the hull runs: handing the same
 array over twice costs one lookup the second time, not a second quickhull.

 @param points : `The cloud, in the mesh's own local space. Not modified, and not retained.`
 @return `The asset's handle, for Scene.add_mesh.`
 @return? TOO_MANY_CONVEX_POINTS : `More than MAX_CONVEX_POINTS. The prelude refuses these first; this is what a forged __three.convex call gets.`
 @return? CONVEX_HULL_IS_DEGENERATE : `The cloud encloses no volume — fewer than four points, or points that are all equal, collinear or coplanar.`
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
