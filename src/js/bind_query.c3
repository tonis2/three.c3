<*
 The bulk spatial verbs, the character controller and the batched write.

 ## Everything here answers into memory the caller already owns

 A host call is cheap; an *allocating* host call is not. So the two verbs that
 can answer with hundreds of things — `queryBox` and `overlapSphere` — take a
 typed array and a capacity, fill it, and answer with a count. The two that
 answer with one thing or a handful — `raycastAll`, `sweep` — build an object,
 because one allocation amortised over a BVH walk is nothing and a hit a script
 has to unpack out of a flat array by hand is worse than a hit.

 ## The typed array crosses as three plain numbers

 `qjs_get_bytes` reads a `Uint8Array` or an `ArrayBuffer` and nothing else, so a
 `Float32Array` is passed as its `buffer`, its `byteOffset` and its `length`. The
 alternative is three property lookups per call on the host side, which is three
 more crossings of a different kind for the same three numbers — and the prelude
 has the values to hand already.
*>
module three;

import std::collections::list;
import std::math;
import std::math::vector;
import collision;
import qjs;

fn void JsRuntime.bind_query_verbs(&self, qjs::Value host)
{
	self.bind(host, "queryBox", &js_query_box, 9);
	self.bind(host, "overlapSphere", &js_overlap_sphere, 7);
	self.bind(host, "raycastAll", &js_raycast_all, 8);
	self.bind(host, "sweep", &js_sweep, 11);
	self.bind(host, "moveAndSlide", &js_move_and_slide, 15);
	self.bind(host, "moveAndSlideAll", &js_move_and_slide_all, 21);
	self.bind(host, "setTransforms", &js_set_transforms, 7);
}

<*
 A view over a script's typed array, from a buffer, a byte offset and a count.

 Bounds-checked here and nowhere else. A byte offset a script got wrong is a
 write into whatever the engine happens to have after that buffer, and the damage
 is silent — so an out-of-range view comes back empty and every caller treats
 empty as "nothing to write".

 @param at : `The argument index of the ArrayBuffer. byteOffset is at + 1 and the element count at + 2.`
*>
fn char[] typed_view(qjs::Context* js, int argc, qjs::Value* args, int at, sz element_size)
{
	if (at + 2 >= argc) return { };
	char[] bytes = js.bytes(args[at]);
	if (bytes.len == 0) return { };

	long offset = (long)arg_number(js, argc, args, at + 1);
	long count  = (long)arg_number(js, argc, args, at + 2);
	if (offset < 0 || count <= 0) return { };

	long wanted = count * (long)element_size;
	if (offset + wanted > (long)bytes.len) return { };
	return bytes[(sz)offset:(sz)wanted];
}

fn float[] float_view(qjs::Context* js, int argc, qjs::Value* args, int at)
{
	char[] bytes = typed_view(js, argc, args, at, 4);
	if (bytes.len == 0) return { };
	return ((float*)bytes.ptr)[:bytes.len / 4];
}

fn int[] int_view(qjs::Context* js, int argc, qjs::Value* args, int at)
{
	char[] bytes = typed_view(js, argc, args, at, 4);
	if (bytes.len == 0) return { };
	return ((int*)bytes.ptr)[:bytes.len / 4];
}

<*
 Writes node handles into an `Int32Array`, two ints apiece.

 The pair rather than the index alone, because a bare index cannot tell slot 7
 from slot 7 after something else was put in it — which is why `NodeId` carries a
 generation, and why `prelude.js` can hand a script back a live object rather
 than a number that used to mean one.
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
 `queryBox(minX, minY, minZ, maxX, maxY, maxZ, buffer, byteOffset, capacity)`.

 `capacity` counts *node slots*, so the Int32Array behind it holds twice that.

 @return `How many nodes were written. Equal to capacity means there may be more.`
*>
fn void js_query_box(
	qjs::ContextRef ctx,
	qjs::Value* this_val,
	int argc,
	qjs::Value* args,
	void* opaque,
	qjs::Value* out
) @local
{
	JsRuntime* self = (JsRuntime*)opaque;
	qjs::Context js = qjs::wrap(ctx);

	collision::Aabb3 box = {
		{ arg_float(&js, argc, args, 0), arg_float(&js, argc, args, 1), arg_float(&js, argc, args, 2) },
		{ arg_float(&js, argc, args, 3), arg_float(&js, argc, args, 4), arg_float(&js, argc, args, 5) },
	};
	box.fix();

	int[] slots = int_view(&js, argc, args, 6);
	if (slots.len < 2)
	{
		*out = qjs::int_value(0);
		return;
	}

	@pool()
	{
		NodeId[] found = mem::temp_array(NodeId, (sz)(slots.len / 2));
		uint count     = self.pass.scene.query_box(&self.pass.assets, box, found);
		*out = qjs::int_value((int)write_handles(slots, found[:(sz)count]));
	};
}

<*
 `overlapSphere(x, y, z, radius, buffer, byteOffset, capacity)`. Same shape as
 `queryBox` and the same counting.
*>
fn void js_overlap_sphere(
	qjs::ContextRef ctx,
	qjs::Value* this_val,
	int argc,
	qjs::Value* args,
	void* opaque,
	qjs::Value* out
) @local
{
	JsRuntime* self = (JsRuntime*)opaque;
	qjs::Context js = qjs::wrap(ctx);

	Vec3 centre  = { arg_float(&js, argc, args, 0), arg_float(&js, argc, args, 1), arg_float(&js, argc, args, 2) };
	float radius = arg_float(&js, argc, args, 3);

	int[] slots = int_view(&js, argc, args, 4);
	if (slots.len < 2)
	{
		*out = qjs::int_value(0);
		return;
	}

	@pool()
	{
		NodeId[] found = mem::temp_array(NodeId, (sz)(slots.len / 2));
		uint count     = self.pass.scene.overlap_sphere(&self.pass.assets, centre, radius, found);
		*out = qjs::int_value((int)write_handles(slots, found[:(sz)count]));
	};
}

<*
 `raycastAll(ox, oy, oz, dx, dy, dz, maxDistance, limit)` — every node the ray
 hits, as an array of the same objects `raycast` answers with.

 An array rather than a typed array, unlike the two above, because of the shape
 of the answer: a hit is a node, a distance, a point and a normal, and packing
 eleven mixed numbers per hit into a flat array for a script to unpack by hand is
 worse than the allocation. The counts differ too — an overlap query answers with
 hundreds and a ray with a handful.

 Not sorted. See `Scene.raycast_all`: sorting means holding everything before
 answering, and a caller who wants the nearest should call `raycast`, which is
 cheaper than sorting because it can stop.
*>
fn void js_raycast_all(
	qjs::ContextRef ctx,
	qjs::Value* this_val,
	int argc,
	qjs::Value* args,
	void* opaque,
	qjs::Value* out
) @local
{
	JsRuntime* self = (JsRuntime*)opaque;
	qjs::Context js = qjs::wrap(ctx);

	Vec3 origin    = { arg_float(&js, argc, args, 0), arg_float(&js, argc, args, 1), arg_float(&js, argc, args, 2) };
	Vec3 direction = { arg_float(&js, argc, args, 3), arg_float(&js, argc, args, 4), arg_float(&js, argc, args, 5) };

	float length = direction.length();
	if (length < 1e-12f)
	{
		*out = js.raise("three.query.raycastAll wants a direction with a length — (0, 0, 0) points nowhere");
		return;
	}

	float max_distance = arg_float(&js, argc, args, 6);
	int limit          = arg_int(&js, argc, args, 7);
	if (limit <= 0) limit = 64;
	if (limit > 4096) limit = 4096;

	collision::Ray ray = { .origin = origin, .direction = direction / length };

	@pool()
	{
		Hit[] hits = mem::temp_array(Hit, (sz)limit);
		uint count = self.pass.scene.raycast_all(&self.pass.assets, ray, max_distance, hits);

		qjs::Value list = js.array();
		for (uint i = 0; i < count; i++) js.set_index(list, i, hit_value(self, &js, hits[i]));
		*out = list;
	};
}

<*
 A `SweepHit` as JavaScript sees it, or `null` for a clear sweep.

 `fraction` is the number a caller integrating a movement wants and `distance` is
 the same thing in world units — both, because a script that thinks in metres
 should not have to multiply by a length it would have to recompute.
*>
fn qjs::Value sweep_value(JsRuntime* self, qjs::Context* js, SweepHit hit) @local
{
	if (!hit.hit) return qjs::null_value();

	qjs::Value found = js.object();
	js.set_property(found, "node", handle_value(js, hit.node));
	js.set_property(found, "fraction", qjs::number_value(hit.fraction));
	js.set_property(found, "distance", qjs::number_value(hit.distance));
	js.set_property(found, "point", vec3_value(js, hit.point));
	js.set_property(found, "normal", vec3_value(js, hit.normal));

	Node* node = self.pass.scene.node(hit.node);
	js.set_property(found, "name", js.string(node == null ? "" : node.name));
	return found;
}

<*
 `sweep(fx, fy, fz, tx, ty, tz, radius, halfHeight, ignoreBuffer,
 ignoreByteOffset, ignoreLength)`.

 An upright capsule, which is a sphere when `halfHeight` is zero. See
 `Scene.sweep_capsule` for why there is no orientation argument.
*>
fn void js_sweep(
	qjs::ContextRef ctx,
	qjs::Value* this_val,
	int argc,
	qjs::Value* args,
	void* opaque,
	qjs::Value* out
) @local
{
	JsRuntime* self = (JsRuntime*)opaque;
	qjs::Context js = qjs::wrap(ctx);

	Vec3 from    = { arg_float(&js, argc, args, 0), arg_float(&js, argc, args, 1), arg_float(&js, argc, args, 2) };
	Vec3 to      = { arg_float(&js, argc, args, 3), arg_float(&js, argc, args, 4), arg_float(&js, argc, args, 5) };
	float radius = arg_float(&js, argc, args, 6);
	float half   = arg_float(&js, argc, args, 7);

	if (!(radius > 0.0f))
	{
		*out = js.raise("three.query.sweep wants a positive radius — a sweep of nothing is three.query.raycast");
		return;
	}

	SweepHit hit = self.pass.scene.sweep_capsule(
		&self.pass.assets,
		from,
		to,
		radius,
		half,
		0.0f,
		ignore_set(self, &js, argc, args, 8)
	);
	*out = sweep_value(self, &js, hit);
}

<*
 The nodes a sweep was told to ignore, out of an `Int32Array` of handle pairs.

 A set rather than one handle, because a character is a Group and a single node
 means a capsule collides with its own chest — `IgnoreSet` carries the argument.
 The prelude fills one shared scratch array rather than allocating per call, so
 the common case of "ignore this one object" costs the same two ints it always
 did.

 Stale handles are dropped rather than raised on: the caller's intent — do not
 collide with that — is satisfied by a node that no longer exists.
 `arg_handle`'s raising is right where a script *named* an object; here an
 absence is an answer.
*>
fn IgnoreSet ignore_set(JsRuntime* self, qjs::Context* js, int argc, qjs::Value* args, int at) @local
{
	int[] pairs = int_view(js, argc, args, at);
	if (pairs.len < 2 || self.pass == null) return { };

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
 `moveAndSlide(px, py, pz, mx, my, mz, radius, halfHeight, step, slope, skin,
 snap, ignoreBuffer, ignoreByteOffset, ignoreLength)`.

 It takes a position and answers with a position; it does not touch a node.
 Handing it the character's object and letting it write the transform reads
 better in one line of script and is wrong in three ways: the capsule's centre
 and the object's origin are almost never the same point, the write would have to
 invert the parent's world matrix to land in local space, and a character that is
 not in the scene graph at all could not be moved. A script writing
 `mesh.position.copy(r.position)` is one JavaScript assignment.
*>
fn void js_move_and_slide(
	qjs::ContextRef ctx,
	qjs::Value* this_val,
	int argc,
	qjs::Value* args,
	void* opaque,
	qjs::Value* out
) @local
{
	JsRuntime* self = (JsRuntime*)opaque;
	qjs::Context js = qjs::wrap(ctx);

	Vec3 centre = { arg_float(&js, argc, args, 0), arg_float(&js, argc, args, 1), arg_float(&js, argc, args, 2) };
	Vec3 motion = { arg_float(&js, argc, args, 3), arg_float(&js, argc, args, 4), arg_float(&js, argc, args, 5) };

	MoveOptions options = default_move_options();
	options.radius = arg_float(&js, argc, args, 6);
	options.half_height = arg_float(&js, argc, args, 7);
	options.step_height = arg_float(&js, argc, args, 8);
	options.slope_limit = arg_float(&js, argc, args, 9);
	options.skin = arg_float(&js, argc, args, 10);
	options.snap = arg_float(&js, argc, args, 11);
	options.dt = (float)self.pass.clock.dt;

	if (!(options.radius > 0.0f))
	{
		*out = js.raise(
			"three.moveAndSlide wants a positive radius — a capsule with none is a point and slides off everything"
		);
		return;
	}

	MoveResult result = self.pass.scene.move_capsule(
		&self.pass.assets,
		centre,
		motion,
		options,
		ignore_set(self, &js, argc, args, 12)
	);

	qjs::Value value = js.object();
	js.set_property(value, "position", vec3_value(&js, result.position));
	js.set_property(value, "remaining", vec3_value(&js, result.remaining));
	js.set_property(value, "grounded", qjs::bool_value(result.grounded));
	js.set_property(value, "slope", qjs::number_value(result.slope));
	js.set_property(value, "stepped", qjs::bool_value(result.stepped));
	js.set_property(value, "slides", qjs::int_value((int)result.slides));
	js.set_property(value, "normal", vec3_value(&js, result.normal));
	js.set_property(value, "ground", result.ground.is_set() ? handle_value(&js, result.ground) : qjs::null_value());
	js.set_property(value, "hit", result.hit.is_set() ? handle_value(&js, result.hit) : qjs::null_value());
	js.set_property(value, "groundVelocity", vec3_value(&js, result.ground_velocity));
	*out = value;
}

<*
 `moveAndSlideAll(posBuffer, posByteOffset, posFloats, motionBuffer,
 motionByteOffset, motionFloats, outBuffer, outByteOffset, outFloats, selfBuffer,
 selfByteOffset, selfInts, radius, halfHeight, step, slope, skin, snap,
 ignoreBuffer, ignoreByteOffset, ignoreLength)`.

 The crowd form of the verb above, and the second of the two places in this API
 where there is exactly one crossing however many agents there are. See
 `Scene.move_capsules` for what it does and for the two decisions in it —
 everyone moving at once, and no node handles in the answer.

 `positions` is read *and written*: it is the caller's position column and it is
 updated where it lies, so nothing has to be copied back out. The options are one
 set for the whole crowd, because a crowd is one agent size; a pack of two sizes
 is two calls over two columns, which is also how it would have to be stored.

 @return `How many agents were stepped.`
*>
fn void js_move_and_slide_all(
	qjs::ContextRef ctx,
	qjs::Value* this_val,
	int argc,
	qjs::Value* args,
	void* opaque,
	qjs::Value* out
) @local
{
	JsRuntime* self = (JsRuntime*)opaque;
	qjs::Context js = qjs::wrap(ctx);

	float[] positions = float_view(&js, argc, args, 0);
	float[] motions   = float_view(&js, argc, args, 3);
	float[] results   = float_view(&js, argc, args, 6);
	int[] selves      = int_view(&js, argc, args, 9);
	if (positions.len < 3 || motions.len < 3)
	{
		*out = qjs::int_value(0);
		return;
	}

	MoveOptions options = default_move_options();
	options.radius = arg_float(&js, argc, args, 12);
	options.half_height = arg_float(&js, argc, args, 13);
	options.step_height = arg_float(&js, argc, args, 14);
	options.slope_limit = arg_float(&js, argc, args, 15);
	options.skin = arg_float(&js, argc, args, 16);
	options.snap = arg_float(&js, argc, args, 17);

	if (!(options.radius > 0.0f))
	{
		*out = js.raise(
			"three.moveAndSlideAll wants a positive radius — a capsule with none is a point and slides off everything"
		);
		return;
	}

	uint stepped = self.pass.scene.move_capsules(
		&self.pass.assets,
		positions,
		motions,
		results,
		options,
		ignore_set(self, &js, argc, args, 18),
		selves
	);
	*out = qjs::int_value((int)stepped);
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
 angle each, typed by a person. Forcing that case through the quaternion form is
 what turns a critter writing a group position, a group heading and two leg
 angles into four crossings a frame at about 380 ns apiece.
*>
const int BATCH_POSITION = 0;
const int BATCH_TRS      = 1;
const int BATCH_EULER    = 2;

<*
 `setTransforms(handleBuffer, handleByteOffset, handleInts, dataBuffer,
 dataByteOffset, dataFloats, mode)` — move many nodes in one crossing.

 Five hundred `mesh.position.set(x, y, z)` measure 0.245 ms a frame — three per
 cent of an eight-millisecond budget — so batching buys nothing anybody can see
 until the count is in the thousands. This is not a faster way to write one
 transform and a script should not reach for it to move a dozen things; it is
 what a crowd, a particle field or a chunked terrain wants, where the write is
 already a loop over a typed array.

 The saving is the crossing and the argument marshalling, not the write: the
 host-side work per node is the same three stores either way.

 A stale handle in the middle of a batch is skipped rather than raising. This is
 a *bulk* verb: a crowd where one agent was removed this frame is ordinary, and
 throwing would abandon the other nine hundred and ninety-nine halfway through
 with no way to tell which. The count answered with is how many actually landed.

 @return `How many nodes were written.`
*>
fn void js_set_transforms(
	qjs::ContextRef ctx,
	qjs::Value* this_val,
	int argc,
	qjs::Value* args,
	void* opaque,
	qjs::Value* out
) @local
{
	JsRuntime* self = (JsRuntime*)opaque;
	qjs::Context js = qjs::wrap(ctx);

	int[] handles = int_view(&js, argc, args, 0);
	float[] data  = float_view(&js, argc, args, 3);
	int mode      = arg_int(&js, argc, args, 6);

	sz stride = mode == BATCH_TRS ? 10 : (mode == BATCH_EULER ? 9 : 3);
	sz count  = handles.len / 2;
	if (count > data.len / stride) count = data.len / stride;
	if (count <= 0)
	{
		*out = qjs::int_value(0);
		return;
	}

	int written = 0;
	for (sz i = 0; i < count; i++)
	{
		NodeId id  = { .index = (uint)handles[i * 2], .generation = (uint)handles[i * 2 + 1] };
		Node* node = self.pass.scene.node(id);
		if (node == null) continue;
		// The same refusal `setTransform` makes — see `PHYSICS_OWNS_TRANSFORM`.
		// Skipped rather than raised, per the header.
		if (self.pass.scene.physics.owns_transform(id)) continue;

		sz at = i * stride;
		node.position = { data[at], data[at + 1], data[at + 2] };
		if (mode == BATCH_EULER)
		{
			// The same conversion `setTransform` makes, so a node written by a
			// batch and a node written by `mesh.rotation.y = h` end up with the same
			// quaternion for the same three numbers.
			node.rotation = quat_from_euler({ data[at + 3], data[at + 4], data[at + 5] });
			node.scale = { data[at + 6], data[at + 7], data[at + 8] };
		}
		else if (mode == BATCH_TRS)
		{
			// A quaternion rather than Euler angles, unlike `setTransform`. A batch
			// is written by arithmetic rather than typed by a person, and the
			// arithmetic that produced it — a look-at, a slerp, a physics read-back
			// — produced a quaternion; converting to Euler to send it and back to
			// compose it is lossy at every gimbal-locked pose. The Euler triple is
			// what a *script* reads back off `.rotation`, and a batched node has no
			// such object to read.
			node.rotation = (Quaternionf) { data[at + 3], data[at + 4], data[at + 5], data[at + 6] }.normalize();
			node.scale = { data[at + 7], data[at + 8], data[at + 9] };
		}
		self.pass.scene.mark_moved(id);
		written++;
	}

	*out = qjs::int_value(written);
}