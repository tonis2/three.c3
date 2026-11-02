<*
 The bulk spatial verbs, the character controller and the batched write.

 ## Everything here answers into memory the caller already owns

 A host call is cheap; an *allocating* host call is not. So the two verbs that
 can answer with hundreds of things — `queryBox` and `overlapSphere` — take an
 `Int32Array`, fill it with node (index, generation) pairs, and answer with a
 count. The two that answer with one thing or a handful — `raycastAll`, `sweep` —
 build an object, because one allocation amortised over a BVH walk is nothing and
 a hit a script has to unpack out of a flat array by hand is worse than a hit.
*>
module three;

import std::collections::list;
import std::math;
import std::math::vector;
import collision;
import fastjs::js;

fn void? JsRuntime.bind_query_verbs(&self, js::Value host)
{
	self.js.@bind(host, "queryBox", &js_query_box, self)!;
	self.js.@bind(host, "overlapSphere", &js_overlap_sphere, self)!;
	self.js.@bind(host, "raycastAll", &js_raycast_all, self)!;
	self.js.@bind(host, "sweep", &js_sweep, self)!;
	self.js.@bind(host, "moveAndSlide", &js_move_and_slide, self)!;
	self.js.@bind(host, "moveAndSlideAll", &js_move_and_slide_all, self)!;
	self.js.@bind(host, "setTransforms", &js_set_transforms, self)!;
}

<*
 Writes node ids into an `Int32Array`, two ints apiece.

 The pair rather than the index alone, because a bare index cannot tell slot 7
 from slot 7 after something else was put in it. `H.nodeAt(index, generation)`
 turns a pair back into the Node handle.
*>
fn uint write_handles(int[] out, NodeId[] found) @local
{
	uint written = 0;
	foreach (id : found)
	{
		if ((sz)(written * 2 + 1) >= out.len) break;
		out[written * 2] = (int)id.index;
		out[written * 2 + 1] = (int)id.generation;
		written++;
	}
	return written;
}

<*
 `queryBox(minX, minY, minZ, maxX, maxY, maxZ, handles)`: every node whose box
 overlaps, as pairs in the `Int32Array` `handles`.

 @return `How many nodes were written. handles.length / 2 means there may be more.`
*>
fn uint js_query_box(JsRuntime* self, Vec3 min, Vec3 max, int[] handles)
{
	if (handles.len < 2) return 0;
	collision::Aabb3 box = { min, max };
	box.fix();
	@pool()
	{
		NodeId[] found = mem::temp_array(NodeId, handles.len / 2);
		uint count     = self.pass.scene.query_box(&self.pass.assets, box, found);
		return write_handles(handles, found[:(sz)count]);
	};
}

<*
 `overlapSphere(x, y, z, radius, handles)`. Same shape as `queryBox` and the same
 counting.
*>
fn uint js_overlap_sphere(JsRuntime* self, Vec3 centre, float radius, int[] handles)
{
	if (handles.len < 2) return 0;
	@pool()
	{
		NodeId[] found = mem::temp_array(NodeId, handles.len / 2);
		uint count     = self.pass.scene.overlap_sphere(&self.pass.assets, centre, radius, found);
		return write_handles(handles, found[:(sz)count]);
	};
}

// One hit of `raycastAll`.
struct QueryHit
{
	NodeId node;
	String name;
	float distance;
	Vec3 point;
	Vec3 normal;
}

// What `sweep` touched. `fraction` is where along the motion, and `distance` is
// the same in world units, so a script that thinks in metres need not multiply.
struct QuerySweepHit
{
	NodeId node;
	String name;
	float fraction;
	float distance;
	Vec3 point;
	Vec3 normal;
}

fn String node_name(JsRuntime* self, NodeId id) @local
{
	Node* node = self.pass.scene.node(id);
	return node == null ? "" : node.name;
}

<*
 `raycastAll(ox, oy, oz, dx, dy, dz, maxDistance, limit)`: every node the ray
 hits, as an array of `{ node, name, distance, point, normal }`.

 Not sorted. See `Scene.raycast_all`: sorting means holding everything before
 answering, and a caller who wants the nearest should call `raycast`, which is
 cheaper than sorting because it can stop.

 @return? js::THREW
*>
fn js::Value? js_raycast_all(JsRuntime* self, Vec3 origin, Vec3 direction, float max_distance, int limit)
{
	float length = direction.length();
	if (length < 1e-12f)
	{
		return self.js.fail("three.query.raycastAll wants a direction with a length — (0, 0, 0) points nowhere")~;
	}
	if (limit <= 0) limit = 64;
	if (limit > 4096) limit = 4096;

	collision::Ray ray = { .origin = origin, .direction = direction / length };

	@pool()
	{
		Hit[] hits = mem::temp_array(Hit, (sz)limit);
		uint count = self.pass.scene.raycast_all(&self.pass.assets, ray, max_distance, hits);

		js::Value list = self.js.array(count)!;
		foreach (hit : hits[:(sz)count])
		{
			QueryHit one = {
				.node = hit.node,
				.name = node_name(self, hit.node),
				.distance = hit.distance,
				.point = hit.point,
				.normal = hit.normal,
			};
			self.js.push(list, self.js.@object_of(one)!);
		}
		return list;
	};
}

<*
 The nodes a sweep was told to ignore: the first `count` (index, generation) pairs
 of an `Int32Array`.

 A set rather than one handle, because a character is a Group and a single node
 means a capsule collides with its own chest. The prelude refills one shared
 scratch array per call, hence the count.

 Stale pairs are dropped rather than raised on: the caller's intent — do not
 collide with that — is satisfied by a node that no longer exists.
*>
fn IgnoreSet ignore_set(JsRuntime* self, int[] pairs, int count) @local
{
	if (count <= 0 || self.pass == null) return { };
	pairs = pairs[:math::min((sz)count * 2, pairs.len)];

	IgnoreSet set;
	for (sz i = 0; i + 1 < pairs.len && set.count < MAX_IGNORED; i += 2)
	{
		if (pairs[i] < 0) continue;
		NodeId id = { .index = (uint)pairs[i], .generation = (uint)pairs[i + 1] };
		if (self.pass.scene.node(id) == null) continue;
		set.nodes[set.count++] = id;
	}
	return set;
}

<*
 `sweep(fx, fy, fz, tx, ty, tz, radius, halfHeight, ignore, ignored)`: the first
 thing an upright capsule touches, or null for a clear sweep. `ignore` is an
 `Int32Array` of node pairs, of which the first `ignored` count.

 A sphere when `halfHeight` is zero. See `Scene.sweep_capsule` for why there is no
 orientation argument.

 @return? js::THREW
*>
fn js::Value? js_sweep(JsRuntime* self, Vec3 from, Vec3 to, float radius, float half, int[] ignore, int ignored)
{
	if (!(radius > 0.0f))
	{
		return self.js.fail("three.query.sweep wants a positive radius — a sweep of nothing is three.query.raycast")~;
	}

	SweepHit hit = self.pass.scene.sweep_capsule(
		&self.pass.assets,
		from,
		to,
		radius,
		half,
		0.0f,
		ignore_set(self, ignore, ignored)
	);
	if (!hit.hit) return js::NULL;
	QuerySweepHit answer = {
		.node = hit.node,
		.name = node_name(self, hit.node),
		.fraction = math::max(hit.fraction, 0.0f),
		.distance = hit.distance,
		.point = hit.point,
		.normal = hit.normal,
	};
	return self.js.@object_of(answer);
}

<*
 `moveAndSlide(px, py, pz, mx, my, mz, radius, halfHeight, step, slope, skin,
 snap, ignore, ignored)`: where the capsule ends up, as a `MoveResult` object
 (`ground` and `hit` are Node handles or null).

 It takes a position and answers with a position; it does not touch a node. The
 capsule's centre and the object's origin are almost never the same point, the
 write would have to invert the parent's world matrix to land in local space, and
 a character that is not in the scene graph at all could not be moved.

 @return? js::THREW
*>
fn MoveResult? js_move_and_slide(
	JsRuntime* self,
	Vec3 centre,
	Vec3 motion,
	float radius,
	float half_height,
	float step_height,
	float slope_limit,
	float skin,
	float snap,
	int[] ignore,
	int ignored
)
{
	MoveOptions options = default_move_options();
	options.radius = radius;
	options.half_height = half_height;
	options.step_height = step_height;
	options.slope_limit = slope_limit;
	options.skin = skin;
	options.snap = snap;
	options.dt = (float)self.pass.clock.dt;

	if (!(options.radius > 0.0f))
	{
		return self.js.fail(
			"three.moveAndSlide wants a positive radius — a capsule with none is a point and slides off everything"
		)~;
	}

	return self.pass.scene.move_capsule(&self.pass.assets, centre, motion, options, ignore_set(self, ignore, ignored));
}

<*
 `moveAndSlideAll(positions, motions, results, selves, radius, halfHeight, step,
 slope, skin, snap, ignore, ignored)`: the crowd form of the verb above, in one
 call however many agents there are. See `Scene.move_capsules` for what it does
 — everyone moving at once, and no node handles in the answer.

 `positions` is read *and written*: it is the caller's position column and it is
 updated where it lies. `results` and `selves` may be left undefined. The options
 are one set for the whole crowd, because a crowd is one agent size.

 @return `How many agents were stepped.`
 @return? js::THREW
*>
fn uint? js_move_and_slide_all(
	JsRuntime* self,
	float[] positions,
	float[] motions,
	float[] results,
	int[] selves,
	float radius,
	float half_height,
	float step_height,
	float slope_limit,
	float skin,
	float snap,
	int[] ignore,
	int ignored
)
{
	if (positions.len < 3 || motions.len < 3) return 0;

	MoveOptions options = default_move_options();
	options.radius = radius;
	options.half_height = half_height;
	options.step_height = step_height;
	options.slope_limit = slope_limit;
	options.skin = skin;
	options.snap = snap;

	if (!(options.radius > 0.0f))
	{
		return self.js.fail(
			"three.moveAndSlideAll wants a positive radius — a capsule with none is a point and slides off everything"
		)~;
	}

	return self.pass.scene.move_capsules(
		&self.pass.assets,
		positions,
		motions,
		results,
		options,
		ignore_set(self, ignore, ignored),
		selves
	);
}

<*
 How a `setTransforms` payload is laid out.

 BATCH_POSITION   3   x y z
 BATCH_TRS       10   x y z   qx qy qz qw   sx sy sz
 BATCH_EULER      9   x y z   rx ry rz      sx sy sz

 Two rotation forms, and they are not redundant. `BATCH_TRS` is for a batch
 written by *arithmetic* — a look-at, a slerp, a physics read-back — where what
 produced the rotation produced a quaternion, and converting it to Euler angles
 to send it would be lossy at every gimbal-locked pose. `BATCH_EULER` is for a
 batch written by a *game*, where the rotation is a heading and a limb swing: one
 angle each, typed by a person, and one call rather than one per part.
*>
const int BATCH_POSITION = 0;
const int BATCH_TRS      = 1;
const int BATCH_EULER    = 2;

<*
 `setTransforms(handles, data, count, mode)`: move the first `count` nodes of a
 batch in one call. `handles` is an `Int32Array` of node pairs and `data` a
 `Float32Array` laid out by `mode`.

 Not a faster way to write one transform: it is what a crowd, a particle field or
 a chunked terrain wants, where the write is already a loop over a typed array.

 A stale handle in the middle of a batch is skipped rather than raising. A crowd
 where one agent was removed this frame is ordinary, and throwing would abandon
 the rest halfway through with no way to tell which landed.

 @return `How many nodes were written.`
*>
fn int js_set_transforms(JsRuntime* self, int[] handles, float[] data, int count, int mode)
{
	sz stride = mode == BATCH_TRS ? 10 : (mode == BATCH_EULER ? 9 : 3);
	sz nodes  = math::min(handles.len / 2, data.len / stride);
	if (count <= 0) return 0;
	if ((sz)count < nodes) nodes = (sz)count;

	int written = 0;
	for (sz i = 0; i < nodes; i++)
	{
		NodeId id  = { .index = (uint)handles[i * 2], .generation = (uint)handles[i * 2 + 1] };
		Node* node = self.pass.scene.node(id);
		if (node == null) continue;
		// The same refusal `setTransform` makes — see `PHYSICS_OWNS_TRANSFORM`.
		// Skipped rather than raised, as above.
		if (self.pass.scene.physics.owns_transform(id)) continue;

		sz at = i * stride;
		node.position = { data[at], data[at + 1], data[at + 2] };
		if (mode == BATCH_EULER)
		{
			// The same conversion `setTransform` makes, so a node written by a
			// batch and one written by `mesh.rotation.y = h` end up with the same
			// quaternion for the same three numbers.
			node.rotation = quat_from_euler({ data[at + 3], data[at + 4], data[at + 5] });
			node.scale = { data[at + 6], data[at + 7], data[at + 8] };
		}
		else if (mode == BATCH_TRS)
		{
			node.rotation = (Quaternionf) { data[at + 3], data[at + 4], data[at + 5], data[at + 6] }.normalize();
			node.scale = { data[at + 7], data[at + 8], data[at + 9] };
		}
		self.pass.scene.mark_moved(id);
		written++;
	}
	return written;
}
