<*
 A 2D outline, with holes cut out of it, swept along +z — Three.js's
 `ExtrudeGeometry` over a `Shape`, and the piece a kit is mostly made of.

 A wall with a window is four boxes today, with coincident faces where they
 meet that nothing will ever see and that still cost a draw call each. This is
 the other answer: one outline, one or more holes, one closed mesh with no
 interior faces.

 ## Two problems, in order

 First, a hole is not part of a convex hull's vocabulary — `collision::quickhull`
 answers "what wraps this cloud", never "what is missing from the middle of it".
 So this does not reuse it. Second, a polygon with holes is not one ring of
 points either; it has to become one before any triangulator can see it, which
 is what `bridge_hole` is for — a zero-width slit from each hole to the outer
 boundary that turns "outline plus holes" into one simple polygon with the holes
 as indentations.

 Once it is a single simple ring, `ear_clip` is exactly `build_convex`'s
 situation one dimension down: a shape description in, three points at a time
 out, flat-shaded with a vertex duplicated per triangle so every face keeps its
 own normal — see that file's header for why coplanar faces still do not share
 vertices here.

 ## Winding, normalised rather than assumed

 A script may draw the outline and its holes in whichever direction is natural
 to it. `build_extrude` fixes the outer ring counter-clockwise and every hole
 clockwise — Three.js's own convention — before anything downstream depends on
 which way is "outward". `render/pass.c3` culls back faces under
 `FRONT_FACE_COUNTER_CLOCKWISE`, so getting this wrong is the same failure
 `primitive.c3`'s header warns about: not a dark patch, a hole you can see the
 inside of the wall through.

 ## Only simple polygons

 `bridge_hole`'s visibility search and `ear_clip`'s containment test both
 assume the outline and every hole are simple — no self-intersection, no
 repeated point, no hole crossing the outer boundary or another hole. A shape
 that breaks that is not detected; it triangulates to whatever the bridge and
 the ear test happen to agree on, same as handing `collision::quickhull` a
 self-intersecting cloud does not detect that either. Well-formed input is the
 caller's half of this, same as it is there.

 Exact collinearity — three vertices on one line, which round numbers reach
 far more often than a hand-drawn plan does, and which a symmetric footprint
 (a plus sign, a centred square hole) reaches on purpose — is handled rather
 than merely tolerated: `point_in_triangle` counts its own boundary as inside,
 so a reflex vertex sitting exactly on the straight edge between two other
 vertices still blocks the ear that would otherwise cut across it. The one
 thing that test would also block by accident is a bridge's own duplicated
 vertex, which necessarily coincides exactly with a real one — so a candidate
 point that exactly equals one of the ear's own three corners is skipped
 before the test runs, rather than let back in through a boundary-exclusive
 rule that cannot tell the two cases apart. See `points_coincide`.

 A ring can still end up with every convex vertex blocked this way — every
 remaining ear touches some other vertex on its boundary — which is what exact
 collinearity can do to a polygon that is otherwise perfectly ordinary.
 `ear_clip` does not fail there: it clips whichever convex candidate has the
 smallest area instead, on the reasoning `EXTRUDE_MIN_FACE_AREA2` already
 argues — a triangle blocked only by a point on its own edge has that point's
 collinearity to thank for however little area it encloses, and dropping it
 loses at most a sliver rather than the shape.

 Two holes exactly the same distance along a bridging ray from each other's
 rightmost point is the same kind of coincidence one level up — a wall with
 two windows at the same height reaches it every time, not as an edge case —
 and ties there are broken toward the nearer of the tied candidates rather
 than whichever the scan saw first, which is what keeps a second hole's
 bridge from reaching past a nearer, safer target and running along a first
 hole's own edge instead of through open material. `EXTRUDE_ANGLE_EPS` is the
 tolerance that comparison needs and `EXTRUDE_EPS` cannot give it — see its
 own header for why a cosine near 1 needs a coarser tie than an area does.

 ## The sides, from the rings rather than from the triangulation

 `bridge_hole` builds a *scratch* ring for triangulating the caps; the seams it
 adds are a triangulation device; they are not real edges and never become a
 wall. The side walls are built straight from the normalised outline and each
 normalised hole, independently of whether or how they were bridged — one quad
 per edge, two triangles, wound so the cross product of its own two edges is
 already the outward direction (into the hole, for a hole's own wall) without a
 second "which way is out" pass like `build_convex`'s `orient_outward` needs for
 an arbitrary hull. A polygon's boundary carries that answer for free: walking a
 counter-clockwise ring keeps the material on the left, so the direction 90°
 clockwise of travel always points outward, and a clockwise hole ring gives the
 same formula the opposite answer, which is "into the hole" — exactly the two
 things this needs and exactly why the winding was normalised first.

 UVs are local by construction, not a projection like a hull's: a cap's uv is
 its own (x, y), and a side's is (distance travelled along its ring, z). There
 is no unwrap to seam because the shape was already flat before it was swept.

 ## The key is a hash, like a hull's

 `extrude_key` hashes the outline, the holes and the depth bit-exact, the same
 argument `convex_key`'s header makes: two shapes built from the same loop are
 the same asset, and a bit different is a different one — cheap for the common
 case (the same array handed over twice) and honest about the uncommon one (two
 clouds that happen to describe the same polygon).
*>
module three;

import std::math;
import std::math::vector;

faultdef EXTRUDE_SHAPE_IS_DEGENERATE, TOO_MANY_EXTRUDE_POINTS;

<*
 Beyond this many points a triangulation is a stall rather than a shape.

 Ear clipping here is the textbook O(n^2) — for every ear it removes it rescans
 what is left — and hole bridging adds an O(n) visibility search per hole on top.
 `MAX_CONVEX_POINTS` can afford 65536 because quickhull is near-linear; this
 cannot, so the cap is far lower. Four thousand is still an outline nobody
 hand-draws and well past the tens of points a floor plan or a kit piece
 actually has.
*>
const uint MAX_EXTRUDE_POINTS = 4096;

<*
 The fewest points that can enclose an area. Fewer is a line or a point.
*>
const uint MIN_EXTRUDE_POINTS = 3;

<*
 A triangle smaller than this, twice over, is not a face — the same guard and
 the same reason as `CONVEX_MIN_FACE_AREA2`: no normal to shade it with, no
 pixels covered, one more index triple a closed-mesh check would have to explain.
*>
const float EXTRUDE_MIN_FACE_AREA2 = 1e-12f;

<*
 The tolerance ear clipping and hole bridging test against zero with — a ring's
 own floating-point roundoff, not a modelling scale. Coordinates a shape is
 actually drawn at (single units to low thousands) keep well clear of it.
*>
const float EXTRUDE_EPS = 1e-9f;

<*
 The tolerance a *cosine* is compared with, which `EXTRUDE_EPS` cannot be:
 that one is sized for a cross product — an area, scale-of-coordinates squared
 — and a cosine is a unitless ratio near 1 where a float32's own precision is
 already about 1.19e-7. `1.0f - 1e-9f` rounds straight back to `1.0f` there,
 which is not a tolerance at all — it is the tie it was supposed to catch,
 silently agreeing with the strict `>` it was meant to widen.
*>
const float EXTRUDE_ANGLE_EPS = 1e-5f;

<*
 One FNV-1a step over a single uint. Split out because `extrude_key` mixes
 outline, holes and depth through the same step, the same reason
 `ribbon_fnv` in `bind_asset.c3` exists.
*>
fn ulong extrude_fnv(ulong hash, uint bits) @local @inline
{
	for (usz byte = 0; byte < 4; byte++)
	{
		hash ^= (ulong)((bits >> (uint)(byte * 8)) & 0xff);
		hash *= 0x100000001b3;
	}
	return hash;
}

fn ulong extrude_hash_points(ulong hash, Vec2[] points) @local
{
	foreach (point : points)
	{
		hash = extrude_fnv(hash, bitcast(point.x, uint));
		hash = extrude_fnv(hash, bitcast(point.y, uint));
	}
	return hash;
}

<*
 The identity of a shape: equal keys mean equal outline, equal holes (in the
 same order, with the same winding) and equal depth.

 Bit-exact, like `convex_key` — see its header for why. `hole_counts` is folded
 in too, and not implied by `holes.len` alone: it is what tells two shapes with
 the same total hole points but split differently (one eight-point hole against
 two four-point ones) apart.
*>
fn String extrude_key(Vec2[] outline, Vec2[] holes, uint[] hole_counts, float depth, Allocator allocator)
{
	ulong hash = 0xcbf29ce484222325;
	hash = extrude_hash_points(hash, outline);
	hash = extrude_hash_points(hash, holes);
	foreach (count : hole_counts) hash = extrude_fnv(hash, count);
	hash = extrude_fnv(hash, bitcast(depth, uint));
	return string::format(allocator, "<extrude n=%d holes=%d h=%x>", outline.len, hole_counts.len, hash);
}

<*
 Twice the signed area of `ring` — the shoelace sum, not halved, because every
 caller here only tests its sign or compares it against a squared-area epsilon.

 Positive means counter-clockwise in the plane as this module always means it:
 x right, y up, seen from +z looking toward -z. That is also the orientation
 whose vertices, wound in order and given a constant z, cross-product to a +z
 normal — which is the fact `build_extrude` spends without re-deriving it.
*>
fn float ring_signed_area(Vec2[] ring)
{
	if (ring.len < 3) return 0;
	float area  = 0;
	usz n       = ring.len;
	for (usz i = 0; i < n; i++)
	{
		area += ring[i].cross(ring[(i + 1) % n]);
	}
	return area;
}

fn void reverse_ring(Vec2[] ring) @local
{
	usz n = ring.len;
	for (usz i = 0; i < n / 2; i++)
	{
		Vec2 tmp        = ring[i];
		ring[i]         = ring[n - 1 - i];
		ring[n - 1 - i] = tmp;
	}
}

<*
 Exact coordinate equality — not a tolerance, because the only points this is
 ever asked about are literal copies: a bridge's duplicated vertex is written
 from the same float twice by `splice_hole`, never recomputed, so two points
 that are meant to be "the same point" always are, to the bit.

 What it is for: `point_in_triangle` now counts its own boundary as inside,
 which is right for a genuine reflex vertex sitting exactly on an ear's edge
 and wrong for the ear's own corners, which of course lie on its boundary too.
 A caller comparing the *rest* of the polygon against a candidate ear uses
 this first to skip anything that is actually one of the ear's own three
 points wearing a different index — a bridge seam, most often — before asking
 whether it blocks.
*>
fn bool points_coincide(Vec2 p, Vec2 q) @local @inline
{
	return p.x == q.x && p.y == q.y;
}

<*
 True when `p` is inside triangle `a, b, c`, or exactly on its boundary.

 Inclusive on purpose: a reflex vertex that sits precisely on the straight
 edge between two other vertices — which round numbers reach far more often
 than a hand-drawn plan does — is not strictly inside the ear that would cut
 across it, but it is still the reason that ear is wrong, and a
 boundary-exclusive test would wave it through. The corresponding false
 positive — a candidate ear's own corner, which is always on its own boundary
 — is the caller's to avoid, with `points_coincide`, because only the caller
 knows which points are the triangle's own and which merely landed on the
 same coordinates.
*>
fn bool point_in_triangle(Vec2 p, Vec2 a, Vec2 b, Vec2 c) @local
{
	float d1 = (p - a).cross(b - a);
	float d2 = (p - b).cross(c - b);
	float d3 = (p - c).cross(a - c);
	// Inside-or-on-boundary is "never on the strictly wrong side of any edge",
	// checked both ways round since the candidate triangle's own winding is
	// not fixed here — `ear_clip` only ever calls this on an already
	// counter-clockwise `a, b, c`, but `bridge_hole`'s `m, crossing, far` is
	// not guaranteed either way.
	bool all_nonneg = d1 >= -EXTRUDE_EPS && d2 >= -EXTRUDE_EPS && d3 >= -EXTRUDE_EPS;
	bool all_nonpos = d1 <= EXTRUDE_EPS && d2 <= EXTRUDE_EPS && d3 <= EXTRUDE_EPS;
	return all_nonneg || all_nonpos;
}

<*
 The two mutations every working ring in this file needs — grow by one in the
 middle, shrink by one in the middle — written directly against a fixed
 backing array and a running count rather than against `std::collections::list`.

 The backing array's capacity is always known upfront here (the final,
 fully-bridged ring's point count, computed once in `triangulate_with_holes`),
 so there is nothing a `List` would buy over an `alloc::new_array` and a `usz`
 that a plain shift-in-place does not: no reallocation ever happens, and every
 caller already has to reason about the same fixed bound to size the array in
 the first place.
*>
fn void insert_at(Vec2[] buffer, usz* count, usz index, Vec2 value) @local
{
	for (usz i = *count; i > index; i--)
	{
		buffer[i] = buffer[i - 1];
	}
	buffer[index] = value;
	*count += 1;
}

fn void remove_at(Vec2[] buffer, usz* count, usz index) @local
{
	for (usz i = index; i + 1 < *count; i++)
	{
		buffer[i] = buffer[i + 1];
	}
	*count -= 1;
}

<*
 Splices `hole`, starting at its `start`'th point, into `outer` right after
 `outer`'s own `visible` point — the bridge.

 Inserts `hole`'s points in their own order starting at `start`, followed by
 `hole[start]` and `outer[visible]` again: the two duplicated vertices that
 turn "outer ring, then a detour around the hole, then back" into one closed
 ring with a zero-width slit rather than two rings. `ear_clip` sees the slit as
 a pair of degenerate triangles and drops them the same way it drops any other
 triangle under `EXTRUDE_MIN_FACE_AREA2`.
*>
fn void splice_hole(Vec2[] outer, usz* outer_count, Vec2[] hole, usz start, usz visible) @local
{
	usz m               = hole.len;
	Vec2 bridge_outer   = outer[visible];
	Vec2 bridge_hole    = hole[start];
	usz at              = visible + 1;
	for (usz j = 0; j < m; j++)
	{
		insert_at(outer, outer_count, at + j, hole[(start + j) % m]);
	}
	insert_at(outer, outer_count, at + m, bridge_hole);
	insert_at(outer, outer_count, at + m + 1, bridge_outer);
}

<*
 Bridges one hole into the working ring `outer`.

 The classic construction: take the hole's rightmost point `m`, cast a ray from
 it toward +x, and the first edge of `outer` the ray crosses names a candidate
 visible point — whichever of that edge's two ends has the larger x. If some
 other vertex of `outer` sits inside the triangle `m`, the ray's crossing point
 and that candidate, it is closer and blocks the view; the vertex among those
 that makes the smallest angle with the ray replaces the candidate, which is
 the one the ray-cast proof relies on to guarantee an unobstructed line still
 exists. `outer` grows by `hole.len + 2` points either way.

 A hole with no edge of `outer` crossing its rightward ray (only reachable from
 a hole that is not actually inside the outline, which `Assets.extrude`'s caller
 is responsible for not asking for) falls back to the nearest point of `outer`
 by distance, so the construction still terminates rather than doing nothing.
*>
fn void bridge_hole(Vec2[] outer, usz* outer_count, Vec2[] hole) @local
{
	usz start = 0;
	for (usz i = 1; i < hole.len; i++)
	{
		if (hole[i].x > hole[start].x || (hole[i].x == hole[start].x && hole[i].y > hole[start].y))
		{
			start = i;
		}
	}
	Vec2 m = hole[start];

	usz n            = *outer_count;
	bool found       = false;
	usz edge_at      = 0;
	float crossing_x = 0;
	for (usz i = 0; i < n; i++)
	{
		Vec2 a = outer[i];
		Vec2 b = outer[(i + 1) % n];
		if ((a.y > m.y) == (b.y > m.y)) continue;
		float t  = (m.y - a.y) / (b.y - a.y);
		float ix = a.x + t * (b.x - a.x);
		if (ix <= m.x) continue;
		if (!found || ix < crossing_x)
		{
			found      = true;
			crossing_x = ix;
			edge_at    = i;
		}
	}

	if (!found)
	{
		usz nearest  = 0;
		float best_d = (outer[0] - m).length_sq();
		for (usz i = 1; i < n; i++)
		{
			float d = (outer[i] - m).length_sq();
			if (d < best_d)
			{
				best_d  = d;
				nearest = i;
			}
		}
		splice_hole(outer, outer_count, hole, start, nearest);
		return;
	}

	Vec2 edge_a   = outer[edge_at];
	Vec2 edge_b   = outer[(edge_at + 1) % n];
	usz idx_a     = edge_at;
	usz idx_b     = (edge_at + 1) % n;
	Vec2 crossing = { crossing_x, m.y };

	// Both ends of the crossing edge are starting candidates, not just
	// whichever has the larger x: on a vertical edge (a wall's corner square
	// on the ray, say) the two ends tie exactly, and picking one by that rule
	// alone means picking arbitrarily — which is what used to make the far
	// corner of a rectangular hole bridge to the wrong side of a wall and
	// triangulate a slice straight across the hole. The nearer end still
	// matters, as the fallback below.
	usz idx_far  = (edge_a - m).length_sq() >= (edge_b - m).length_sq() ? idx_a : idx_b;
	Vec2 far     = outer[idx_far];

	// cos of the angle between (candidate - m) and the +x ray: larger is a
	// smaller angle, which is the rule that picks the vertex closest to the
	// ray's own direction among everything that can see `m`. Ties in that
	// angle are broken toward the *nearer* candidate rather than whichever
	// was seen first — two points exactly on the ray from `m` are exactly the
	// shape two holes at the same height produce (one hole's own rightmost
	// point can sit exactly as far along the ray as another's), and the
	// farther of a tied pair is the one whose bridge segment then runs along
	// something else's boundary instead of through open material.
	usz visible;
	float best_cos;
	float best_len;
	{
		Vec2 to_a = edge_a - m;
		best_len  = to_a.length();
		visible   = idx_a;
		best_cos  = best_len > 0 ? to_a.x / best_len : 1.0f;

		Vec2 to_b   = edge_b - m;
		float len_b = to_b.length();
		float cos_b = len_b > 0 ? to_b.x / len_b : 1.0f;
		if (cos_b > best_cos + EXTRUDE_ANGLE_EPS || (cos_b > best_cos - EXTRUDE_ANGLE_EPS && len_b < best_len))
		{
			best_cos = cos_b;
			best_len = len_b;
			visible  = idx_b;
		}
	}

	// A reflex vertex inside triangle (m, crossing, far) can still steal
	// visibility from either starting candidate. `far` rather than whichever
	// of the two is currently ahead: `crossing` lies on the segment between
	// `edge_a` and `edge_b` by construction, so the triangle built on the
	// nearer one is already inside the triangle built on the farther one, and
	// searching the larger of the two misses nothing the smaller would have
	// found. `point_in_triangle` counts its own boundary as inside, so a
	// vertex that happens to coincide with `m`, `crossing` or `far` itself —
	// which does not occur in this search's own indices but is cheap to rule
	// out on the coordinates too, the same guard `ear_clip` needs — is skipped
	// rather than trivially "found".
	for (usz i = 0; i < n; i++)
	{
		if (i == idx_a || i == idx_b) continue;
		Vec2 v = outer[i];
		if (points_coincide(v, m) || points_coincide(v, crossing) || points_coincide(v, far)) continue;
		if (!point_in_triangle(v, m, crossing, far)) continue;
		Vec2 to_v = v - m;
		float len = to_v.length();
		if (len <= 0) continue;
		float cosang = to_v.x / len;
		if (cosang > best_cos + EXTRUDE_ANGLE_EPS || (cosang > best_cos - EXTRUDE_ANGLE_EPS && len < best_len))
		{
			best_cos = cosang;
			best_len = len;
			visible  = i;
		}
	}

	splice_hole(outer, outer_count, hole, start, visible);
}

<*
 Ear-clips the simple polygon `ring` and appends its triangles to `out`, three
 `Vec2`s at a time, in the same winding `ring` itself is wound in.

 Standard removal: a point is an ear when the two edges either side of it turn
 the same way the whole ring turns, and no other point of what is left sits
 inside the triangle those three points make, or exactly on its boundary —
 see `point_in_triangle`'s header for why the boundary counts, and
 `points_coincide` for the one case that has to be carved back out of it, a
 candidate ear's own corner reappearing as a bridge seam's duplicate. Clipping
 an ear and repeating leaves `n - 2` triangles for an `n`-point simple ring.

 Exact collinearity can still leave every convex vertex blocked by some other
 point sitting exactly on its boundary — a symmetric footprint reaches this on
 purpose, a bridge seam reaches it by construction, and a script working in
 round numbers reaches it more than a hand-drawn plan does. Rather than fail
 there, the scan also tracks the convex candidate with the smallest triangle
 area as it goes, and clips that one if nothing ever comes back unblocked: a
 triangle that is only ever blocked by a point on its own edge has that
 point's collinearity to thank for however little area it enclosed in the
 first place, so cutting it loses at most a sliver, never the shape, and
 `EXTRUDE_MIN_FACE_AREA2` drops it outright if the sliver is nothing at all.
 `count` still strictly decreases either way, so this terminates in at most
 `ring.len()` steps regardless of how it got there.
*>
fn void push_triangle(Vec2[] out, usz* out_count, Vec2 a, Vec2 b, Vec2 c) @local
{
	usz at      = *out_count;
	out[at]     = a;
	out[at + 1] = b;
	out[at + 2] = c;
	*out_count  = at + 3;
}

fn void ear_clip(Vec2[] out, usz* out_count, Vec2[] ring) @local
{
	if (ring.len < 3) return;

	Vec2[] points = alloc::new_array(tmem, Vec2, (sz)ring.len);
	for (usz i = 0; i < ring.len; i++) points[i] = ring[i];
	usz count = ring.len;

	while (count > 3)
	{
		usz m = count;

		usz chosen = m;
		// The smallest-area convex candidate seen this pass, in case nothing
		// ever comes back unblocked — see the header.
		usz fallback        = m;
		float fallback_area2 = 0;

		for (usz i = 0; i < m; i++)
		{
			usz prev = (i + m - 1) % m;
			usz next = (i + 1) % m;
			Vec2 a   = points[prev];
			Vec2 b   = points[i];
			Vec2 c   = points[next];
			if ((b - a).cross(c - b) <= EXTRUDE_EPS) continue;

			bool empty = true;
			for (usz j = 0; j < m; j++)
			{
				if (j == prev || j == i || j == next) continue;
				Vec2 v = points[j];
				if (points_coincide(v, a) || points_coincide(v, b) || points_coincide(v, c)) continue;
				if (point_in_triangle(v, a, b, c))
				{
					empty = false;
					break;
				}
			}

			if (empty)
			{
				chosen = i;
				break;
			}

			float area2 = math::abs((b - a).cross(c - a));
			if (fallback == m || area2 < fallback_area2)
			{
				fallback       = i;
				fallback_area2 = area2;
			}
		}

		if (chosen == m) chosen = fallback != m ? fallback : 0;

		usz prev = (chosen + m - 1) % m;
		usz next = (chosen + 1) % m;
		Vec2 a   = points[prev];
		Vec2 b   = points[chosen];
		Vec2 c   = points[next];
		if (math::abs((b - a).cross(c - a)) > EXTRUDE_MIN_FACE_AREA2)
		{
			push_triangle(out, out_count, a, b, c);
		}
		remove_at(points, &count, chosen);
	}

	if (count == 3)
	{
		Vec2 a = points[0];
		Vec2 b = points[1];
		Vec2 c = points[2];
		if (math::abs((b - a).cross(c - a)) > EXTRUDE_MIN_FACE_AREA2)
		{
			push_triangle(out, out_count, a, b, c);
		}
	}
}

<*
 Bridges every hole into a copy of `outline` and ear-clips the result —
 `outline` and `holes` themselves are left untouched, since the sides still
 need them in their own, unbridged form.

 Holes are bridged in order of decreasing rightmost x, the one ordering rule
 the bridge construction needs: bridging the hole furthest to the right first
 keeps a later hole's bridge from being able to cross an earlier one.
*>
fn void triangulate_with_holes(Vec2[] out, usz* out_count, Vec2[] outline, Vec2[] holes, uint[] hole_counts) @local
{
	usz outer_cap   = outline.len + holes.len + hole_counts.len * 2;
	Vec2[] outer    = alloc::new_array(tmem, Vec2, (sz)outer_cap);
	usz outer_count = outline.len;
	for (usz i = 0; i < outline.len; i++) outer[i] = outline[i];

	if (hole_counts.len > 0)
	{
		usz[] offsets    = alloc::new_array(tmem, usz, (sz)hole_counts.len);
		float[] rightmost = alloc::new_array(tmem, float, (sz)hole_counts.len);
		usz[] order      = alloc::new_array(tmem, usz, (sz)hole_counts.len);

		usz offset = 0;
		for (usz i = 0; i < hole_counts.len; i++)
		{
			offsets[i] = offset;
			Vec2[] slice = holes[offset..][:hole_counts[i]];
			float rx     = slice[0].x;
			foreach (p : slice) if (p.x > rx) rx = p.x;
			rightmost[i] = rx;
			order[i]     = i;
			offset += hole_counts[i];
		}

		// Insertion sort, descending: `hole_counts.len` is a handful of holes
		// in the shapes this is for, and simple beats fast at that size.
		for (usz i = 1; i < order.len; i++)
		{
			usz key      = order[i];
			float key_x  = rightmost[key];
			usz j        = i;
			while (j > 0 && rightmost[order[j - 1]] < key_x)
			{
				order[j] = order[j - 1];
				j--;
			}
			order[j] = key;
		}

		foreach (idx : order)
		{
			Vec2[] slice = holes[offsets[idx]..][:hole_counts[idx]];
			bridge_hole(outer, &outer_count, slice);
		}
	}

	ear_clip(out, out_count, outer[0:outer_count]);
}

<*
 Pushes one flat-shaded cap triangle at height `z`, facing +z if `top` else -z.

 `top` also picks the winding: `a, b, c` for the +z cap (already
 counter-clockwise, per `ring_signed_area`'s header) and `a, c, b` for the -z
 one, which is the one place `build_extrude` states "reversed winding" instead
 of computing it — the two caps are the same triangles at two different z's and
 opposite normals, and swapping two corners is the whole difference.
*>
fn void push_cap_triangle(GeometryBuilder* out, Vec2 a, Vec2 b, Vec2 c, float z, bool top) @local
{
	Vec3 normal = top ? (Vec3) { 0, 0, 1 } : (Vec3) { 0, 0, -1 };
	Vec3 pa     = { a.x, a.y, z };
	Vec3 pb     = { b.x, b.y, z };
	Vec3 pc     = { c.x, c.y, z };

	uint first = (uint)out.positions.len();
	out.positions.push(pa);
	out.normals.push(normal);
	out.uvs.push(a);
	out.positions.push(top ? pb : pc);
	out.normals.push(normal);
	out.uvs.push(top ? b : c);
	out.positions.push(top ? pc : pb);
	out.normals.push(normal);
	out.uvs.push(top ? c : b);
	out.triangle(first, first + 1, first + 2);
}

<*
 One quad, two triangles, per edge of `ring` from z = 0 to z = `depth`.

 The winding is `(b0, b1, t1)` then `(b0, t1, t0)` — bottom-near, bottom-far,
 top-far / bottom-near, top-far, top-near — chosen so the cross product of its
 own two edges already points outward with no separate "which way is out" test:
 `(b1 - b0) x (t1 - b1)` works out to `depth * (dy, -dx, 0)` for an edge
 direction `(dx, dy)`, which is 90° clockwise of travel — outward for a
 counter-clockwise ring, into the hole for a clockwise one, per this file's
 header.

 The uv is local: `u` is distance travelled along `ring` since its own first
 point, `v` is `z`. An edge shorter than `EXTRUDE_EPS` (two coincident points in
 the input) contributes no quad and no distance — nothing to give a normal to.
*>
fn void build_sides(GeometryBuilder* out, Vec2[] ring, float depth) @local
{
	usz n = ring.len;
	if (n < 2) return;

	float distance = 0;
	for (usz i = 0; i < n; i++)
	{
		Vec2 p0 = ring[i];
		Vec2 p1 = ring[(i + 1) % n];
		float edge_length = (p1 - p0).length();
		if (edge_length < EXTRUDE_EPS) continue;

		float d0 = distance;
		float d1 = distance + edge_length;
		distance = d1;

		Vec3 b0 = { p0.x, p0.y, 0 };
		Vec3 b1 = { p1.x, p1.y, 0 };
		Vec3 t1 = { p1.x, p1.y, depth };
		Vec3 t0 = { p0.x, p0.y, depth };

		Vec3 normal    = (b1 - b0).cross(t1 - b1);
		float side_len = normal.length();
		normal = side_len > 0 ? normal / side_len : normal;

		uint first = (uint)out.positions.len();
		out.positions.push(b0);
		out.normals.push(normal);
		out.uvs.push({ d0, 0 });
		out.positions.push(b1);
		out.normals.push(normal);
		out.uvs.push({ d1, 0 });
		out.positions.push(t1);
		out.normals.push(normal);
		out.uvs.push({ d1, depth });
		out.triangle(first, first + 1, first + 2);

		first = (uint)out.positions.len();
		out.positions.push(b0);
		out.normals.push(normal);
		out.uvs.push({ d0, 0 });
		out.positions.push(t1);
		out.normals.push(normal);
		out.uvs.push({ d1, depth });
		out.positions.push(t0);
		out.normals.push(normal);
		out.uvs.push({ d0, depth });
		out.triangle(first, first + 1, first + 2);
	}
}

<*
 Fills `out` with the flat-shaded surface of `outline` (with `holes` cut out of
 it) swept from z = 0 to z = `depth`.

 Left empty when the shape is degenerate: fewer than 3 outline points, an
 outline with no area, or a hole with fewer than 3 points. The caller reports
 that — same contract `build_convex` has with `Assets.convex`.

 `outline` and `holes` are normalised to Three.js's winding in place (outer
 counter-clockwise, every hole clockwise) before anything is built, so a script
 may draw either direction — see this file's header.

 @param outline : `The outer boundary, in the mesh's own local xy. Mutated in place to fix its winding.`
 @param holes : `Every hole's points, concatenated. Mutated in place to fix each hole's winding.`
 @param hole_counts : `How many of holes' points belong to each hole, in order.`
 @param depth : `How far along +z the shape is swept. Must be positive; not checked here.`
*>
fn void build_extrude(GeometryBuilder* out, Vec2[] outline, Vec2[] holes, uint[] hole_counts, float depth)
{
	if (outline.len < MIN_EXTRUDE_POINTS) return;
	if (math::abs(ring_signed_area(outline)) < EXTRUDE_EPS) return;
	foreach (count : hole_counts) if (count < MIN_EXTRUDE_POINTS) return;

	if (ring_signed_area(outline) < 0) reverse_ring(outline);

	usz offset = 0;
	for (usz i = 0; i < hole_counts.len; i++)
	{
		Vec2[] slice = holes[offset..][:hole_counts[i]];
		if (ring_signed_area(slice) > 0) reverse_ring(slice);
		offset += hole_counts[i];
	}

	// The final, fully-bridged ring is `outline.len + holes.len` real points
	// plus two duplicated bridge vertices per hole; a simple ring of that many
	// points ear-clips to at most that many minus two triangles.
	usz ring_points          = outline.len + holes.len + hole_counts.len * 2;
	usz max_triangle_points  = 3 * (ring_points - 2);
	Vec2[] triangles         = alloc::new_array(tmem, Vec2, (sz)max_triangle_points);
	usz triangle_points      = 0;
	triangulate_with_holes(triangles, &triangle_points, outline, holes, hole_counts);

	usz triangle_count = triangle_points / 3;
	for (usz t = 0; t < triangle_count; t++)
	{
		Vec2 a = triangles[t * 3];
		Vec2 b = triangles[t * 3 + 1];
		Vec2 c = triangles[t * 3 + 2];
		push_cap_triangle(out, a, b, c, depth, true);
		push_cap_triangle(out, a, b, c, 0, false);
	}

	build_sides(out, outline, depth);
	offset = 0;
	for (usz i = 0; i < hole_counts.len; i++)
	{
		Vec2[] slice = holes[offset..][:hole_counts[i]];
		build_sides(out, slice, depth);
		offset += hole_counts[i];
	}
}

<*
 Triangulates `outline` (with `holes` cut out of it), sweeps it from z = 0 to
 `depth`, and uploads it, or answers with the asset already built for exactly
 this shape.

 The dedup is `Assets.primitive`'s and `Assets.convex`'s: checked against
 `extrude_key` before any triangulation runs, so handing the same shape over
 twice costs one lookup the second time, not a second triangulation.

 @param outline : `The outer boundary, in the mesh's own local xy. Not retained.`
 @param holes : `Every hole's points, concatenated. Not retained.`
 @param hole_counts : `How many of holes' points belong to each hole, in order.`
 @param depth : `How far along +z the shape is swept.`
 @return `The asset's handle, for Scene.add_mesh.`
 @return ? TOO_MANY_EXTRUDE_POINTS : `More than MAX_EXTRUDE_POINTS total points across the outline and every hole. The prelude refuses these first; this is what a forged __three.extrude call gets.`
 @return ? EXTRUDE_SHAPE_IS_DEGENERATE : `The outline has fewer than 3 points or no area, or a hole has fewer than 3 points.`
*>
fn AssetId? Assets.extrude(&self, Gpu* gpu, Vec2[] outline, Vec2[] holes, uint[] hole_counts, float depth)
{
	if (!self.started) self.init();
	if (outline.len + holes.len > MAX_EXTRUDE_POINTS) return TOO_MANY_EXTRUDE_POINTS~;

	@pool()
	{
		String key = extrude_key(outline, holes, hole_counts, depth, tmem);
		if (try hit = self.built(key)) return hit;

		GeometryBuilder geometry;
		geometry.init();
		defer geometry.free();
		build_extrude(&geometry, outline, holes, hole_counts, depth);

		if (geometry.indices.len() < 3) return EXTRUDE_SHAPE_IS_DEGENERATE~;

		return self.upload_built(gpu, key, "extrude", &geometry);
	};
}
