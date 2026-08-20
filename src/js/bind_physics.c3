<*
 The physics verbs — `game.md` G5/S3, S6, S7.

	mesh.body = { shape: 'box', mass: 1, friction: 0.5, restitution: 0.2 }
	three.physics.add(mesh)
	three.physics.remove(mesh)
	three.physics.gravity = [0, -9.8, 0]
	three.physics.velocity(mesh)                     // and setVelocity
	three.physics.applyImpulse(mesh, [0, 5, 0])
	three.onTrigger(e => ...)
	three.onContact(e => ...)

 **Velocity and impulse are what make a character possible**, and until they
 were bound there was no combination of the verbs above that both walks and
 collides: a dynamic body could be dropped and watched but never steered, and a
 kinematic one was steered but never stopped. The solver had
 `apply_linear_impulse` and `linear_velocity` all along
 (`collision.c3l` `solver/resolver.c3`); nothing here reached them, so
 `examples/village` walked its character with 123 hand-registered circles and
 rectangles resolved in JavaScript every frame.

 **Events reuse the keyboard's machinery** (G5/S7), which is the whole of this
 file's second half: same registration shape, same "a handler that throws is
 stopped for good" policy, same frame log. A solver event and a keypress are the
 same kind of thing from a script's side — something that happened, delivered
 once, inside the frame.

 **The solver owns a dynamic body's transform** (G5/S6), and the refusal for
 that lives in `bind_scene.c3` where the writes arrive rather than here.
*>
module three;

import std::io;
import std::collections::object;
import std::core::string;
import collision;
import qjs;
import std::math::vector;

fn void JsRuntime.bind_physics_verbs(&self, qjs::Value host)
{
	self.bind(host, "physicsAdd", &js_physics_add, 7);
	self.bind(host, "physicsRemove", &js_physics_remove, 2);
	self.bind(host, "physicsGravitySet", &js_physics_gravity_set, 3);
	self.bind(host, "physicsGravityGet", &js_physics_gravity_get, 0);
	self.bind(host, "physicsCount", &js_physics_count, 0);
	self.bind(host, "physicsTransform", &js_physics_transform, 2);
	self.bind(host, "physicsVelocityGet", &js_physics_velocity_get, 2);
	self.bind(host, "physicsLinearSet", &js_physics_linear_set, 5);
	self.bind(host, "physicsAngularSet", &js_physics_angular_set, 5);
	self.bind(host, "physicsImpulse", &js_physics_impulse, 8);
	self.bind(host, "physicsTorqueImpulse", &js_physics_torque_impulse, 5);
	self.bind(host, "onTrigger", &js_on_trigger, 1);
	self.bind(host, "onContact", &js_on_contact, 1);
}

<*
 `physicsAdd(index, generation, kind, shape, mass, friction, restitution)`.

 Strings for the two enums rather than numbers, because they cross once per body
 and a script that mistypes one should be told which word was wrong rather than
 handed body 7 of a scene it did not build.
*>
fn void js_physics_add(
	qjs::ContextRef ctx, qjs::Value* this_val, int argc, qjs::Value* args, void* opaque, qjs::Value* out
) @local
{
	JsRuntime* self = (JsRuntime*)opaque;
	qjs::Context js = qjs::wrap(ctx);

	NodeId id = arg_handle(self, &js, argc, args, 0, out);
	if (!id.is_set()) return;

	@pool()
	{
		String kind_name = arg_text(&js, argc, args, 2, tmem);
		String shape_name = arg_text(&js, argc, args, 3, tmem);

		BodyKind kind;
		switch (kind_name)
		{
			case "dynamic": kind = BodyKind.DYNAMIC;
			case "static": kind = BodyKind.STATIC;
			case "kinematic": kind = BodyKind.KINEMATIC;
			case "trigger": kind = BodyKind.TRIGGER;
			default:
				*out = js.raise(string::tformat(
					"'%s' is not a body kind — it is one of dynamic, static, kinematic or trigger",
					kind_name
				));
				return;
		}

		ColliderShape shape;
		switch (shape_name)
		{
			case "box": shape = ColliderShape.BOX;
			case "sphere": shape = ColliderShape.SPHERE;
			case "capsule": shape = ColliderShape.CAPSULE;
			case "hull": shape = ColliderShape.HULL;
			default:
				*out = js.raise(string::tformat(
					"'%s' is not a collider shape — it is one of box, sphere, capsule or hull",
					shape_name
				));
				return;
		}

		float mass = arg_float(&js, argc, args, 4);
		float friction = arg_float(&js, argc, args, 5);
		float restitution = arg_float(&js, argc, args, 6);

		if (catch err = self.physics.add(
			&self.pass.scene, &self.pass.assets, id, kind, shape, mass, friction, restitution
		))
		{
			*out = js.raise(physics_add_message(err, shape_name));
			return;
		}
	};
}

<*
 A sentence for each way `Physics.add` refuses, rather than the fault's name.

 Each of these is a thing a script did, and each has a different next step —
 which is the whole reason they are separate faults and not one.
*>
fn String physics_add_message(fault err, String shape_name) @local
{
	switch (err)
	{
		case NODE_HAS_NO_MESH:
			return "this object draws nothing, so there is no size to build a collider from — "
				"give the body to a mesh rather than to a group";
		case MESH_HAS_NO_HULL:
			return string::tformat(
				"a '%s' collider needs the mesh's own points and this mesh has none on the host — "
				"it may not have been drawn yet, and 'box' works from bounds alone",
				shape_name
			);
		case NODE_IS_NOT_TOP_LEVEL:
			return "a body-backed object has to be a child of the scene, not of another object — "
				"the solver works in world space and a parent transform would fight it";
		default:
			return string::tformat("the body could not be added: %s", err);
	}
}

<*
 `physicsRemove(index, generation)` — true when there was one.
*>
fn void js_physics_remove(
	qjs::ContextRef ctx, qjs::Value* this_val, int argc, qjs::Value* args, void* opaque, qjs::Value* out
) @local
{
	JsRuntime* self = (JsRuntime*)opaque;
	qjs::Context js = qjs::wrap(ctx);

	NodeId id = arg_handle(self, &js, argc, args, 0, out);
	if (!id.is_set()) return;

	*out = qjs::bool_value(self.physics.remove(id));
}

fn void js_physics_gravity_set(
	qjs::ContextRef ctx, qjs::Value* this_val, int argc, qjs::Value* args, void* opaque, qjs::Value* out
) @local
{
	JsRuntime* self = (JsRuntime*)opaque;
	qjs::Context js = qjs::wrap(ctx);

	self.physics.set_gravity({
		arg_float(&js, argc, args, 0),
		arg_float(&js, argc, args, 1),
		arg_float(&js, argc, args, 2),
	});
}

fn void js_physics_gravity_get(
	qjs::ContextRef ctx, qjs::Value* this_val, int argc, qjs::Value* args, void* opaque, qjs::Value* out
) @local
{
	JsRuntime* self = (JsRuntime*)opaque;
	qjs::Context js = qjs::wrap(ctx);

	// Reported before the world is opened too, so reading gravity is not the
	// thing that creates a world.
	Vec3 gravity = self.physics.opened ? self.physics.world.gravity : PHYSICS_GRAVITY;

	qjs::Value triple = js.array();
	js.set_index(triple, 0, qjs::number_value((double)gravity.x));
	js.set_index(triple, 1, qjs::number_value((double)gravity.y));
	js.set_index(triple, 2, qjs::number_value((double)gravity.z));
	*out = triple;
}

<*
 `physicsTransform(index, generation)` — where the solver has put a node, as
 `[px, py, pz, ex, ey, ez]`.

 **The read-back door, and the only one there is.** `prelude.js` holds a node's
 transform as JavaScript numbers and pushes them on write, which is exactly
 right while a script is the only writer — and leaves `mesh.position` reporting
 where a script last put a falling body rather than where it fell to. So a
 solver-owned object refreshes through here before it answers.

 Euler rather than the quaternion the node actually stores, because `rotation`
 is an Euler triple on the JavaScript side and `euler_from_quat` is already the
 one place that converts backwards for exactly this reason.
*>
fn void js_physics_transform(
	qjs::ContextRef ctx, qjs::Value* this_val, int argc, qjs::Value* args, void* opaque, qjs::Value* out
) @local
{
	JsRuntime* self = (JsRuntime*)opaque;
	qjs::Context js = qjs::wrap(ctx);

	NodeId id = arg_handle(self, &js, argc, args, 0, out);
	if (!id.is_set()) return;

	Node* node = self.pass.scene.node(id);
	if (node == null)
	{
		*out = qjs::null_value();
		return;
	}

	Vec3 euler = euler_from_quat(node.rotation);
	qjs::Value six = js.array();
	js.set_index(six, 0, qjs::number_value((double)node.position.x));
	js.set_index(six, 1, qjs::number_value((double)node.position.y));
	js.set_index(six, 2, qjs::number_value((double)node.position.z));
	js.set_index(six, 3, qjs::number_value((double)euler.x));
	js.set_index(six, 4, qjs::number_value((double)euler.y));
	js.set_index(six, 5, qjs::number_value((double)euler.z));
	*out = six;
}

// ---------------------------------------------------------------------------
// Velocity and impulse
//
// Five verbs over three solver calls. What they share is the guard: each one
// resolves the node, refuses a body the solver does not integrate, and wakes the
// island before touching anything. Skipping the wake is the failure worth naming
// twice — a sleeping body absorbs an impulse into a number nothing reads, so the
// same line of script works on a rolling crate and does nothing at all to a
// settled one, which reads as the verb being unreliable rather than as sleep.

<*
 Resolve a node to a body that may be pushed, or raise saying why not.

 Three different refusals rather than one, because they are three different
 mistakes and the fix for each is a different line of script.
*>
fn collision::Rigidbody* pushable(
	JsRuntime* self, qjs::Context* js, int argc, qjs::Value* args, qjs::Value* out, String verb
) @local
{
	NodeId id = arg_handle(self, js, argc, args, 0, out);
	if (!id.is_set()) return null;

	PhysicsBody* body = self.physics.body_for(id);
	if (body == null)
	{
		*out = js.raise(string::tformat("%s needs a body — three.physics.add(object) first", verb));
		return null;
	}
	if (body.kind == BodyKind.STATIC)
	{
		*out = js.raise(string::tformat(
			"%s cannot move a static body: its inverse mass is zero, so an impulse is arithmetically nothing. Give it a mass, or move its transform directly",
			verb
		));
		return null;
	}
	if (body.kind == BodyKind.KINEMATIC)
	{
		*out = js.raise(string::tformat(
			"%s cannot move a kinematic body: the solver drives it from the transform your script writes, so a velocity set here is discarded a fraction of a step later. Move object.position instead",
			verb
		));
		return null;
	}
	if (body.kind == BodyKind.TRIGGER)
	{
		*out = js.raise(string::tformat("%s cannot move a trigger: a trigger detects overlaps and is never integrated", verb));
		return null;
	}

	collision::Rigidbody* rigid = self.physics.rigidbody_for(id);
	if (rigid == null)
	{
		*out = js.raise(string::tformat("%s found the body's record but not the solver's, which should not happen", verb));
		return null;
	}
	self.physics.wake(rigid);
	return rigid;
}

<*
 `physicsVelocityGet(index, generation)` — `[lx, ly, lz, ax, ay, az]`, or null.

 Null rather than a raise for the same reason `physicsTransform` answers null: a
 getter is asked in a loop over things that may or may not have bodies, and
 making that a throw would mean writing the check twice in every such loop.

 Both velocities in one array rather than two crossings, because a script that
 wants one usually wants the other in the same breath — a character reads linear
 to decide whether it is moving and angular to decide whether it has been spun.

 Answers for every kind of body, unlike the setters. Reading a kinematic body's
 velocity is how a script finds out how fast the transform it is writing is
 actually carrying the thing, which is a real question with a real answer.
*>
fn void js_physics_velocity_get(
	qjs::ContextRef ctx, qjs::Value* this_val, int argc, qjs::Value* args, void* opaque, qjs::Value* out
) @local
{
	JsRuntime* self = (JsRuntime*)opaque;
	qjs::Context js = qjs::wrap(ctx);

	NodeId id = arg_handle(self, &js, argc, args, 0, out);
	if (!id.is_set()) return;

	collision::Rigidbody* rigid = self.physics.rigidbody_for(id);
	if (rigid == null)
	{
		*out = qjs::null_value();
		return;
	}

	qjs::Value six = js.array();
	js.set_index(six, 0, qjs::number_value((double)rigid.linear_velocity.x));
	js.set_index(six, 1, qjs::number_value((double)rigid.linear_velocity.y));
	js.set_index(six, 2, qjs::number_value((double)rigid.linear_velocity.z));
	js.set_index(six, 3, qjs::number_value((double)rigid.angular_velocity.x));
	js.set_index(six, 4, qjs::number_value((double)rigid.angular_velocity.y));
	js.set_index(six, 5, qjs::number_value((double)rigid.angular_velocity.z));
	*out = six;
}

<*
 `physicsLinearSet(index, generation, x, y, z)` — units per second, world space.

 **Assignment, not addition**, and that is the difference from an impulse that
 matters at a call site. A character sets its velocity every frame from the keys
 that are down, because what it wants is a speed; a explosion applies an impulse,
 because what it wants is a change to whatever the speed already was. Getting
 this backwards gives a character that accelerates forever.

 The solver reconstructs `linear_velocity` from the position delta at the end of
 every step (`resolver.c3`'s `body.linear_velocity = (position - prev) * inv_dt`),
 so what is written here survives exactly one integration and then becomes
 whatever actually happened — which is the right behaviour and the reason a
 character sets it again next frame rather than once.
*>
fn void js_physics_linear_set(
	qjs::ContextRef ctx, qjs::Value* this_val, int argc, qjs::Value* args, void* opaque, qjs::Value* out
) @local
{
	JsRuntime* self = (JsRuntime*)opaque;
	qjs::Context js = qjs::wrap(ctx);

	collision::Rigidbody* rigid = pushable(self, &js, argc, args, out, "three.physics.setVelocity");
	if (rigid == null) return;

	rigid.linear_velocity = {
		arg_float(&js, argc, args, 2), arg_float(&js, argc, args, 3), arg_float(&js, argc, args, 4)
	};
}

<*
 `physicsAngularSet(index, generation, x, y, z)` — radians per second about each
 world axis, the vector's length being the rate.
*>
fn void js_physics_angular_set(
	qjs::ContextRef ctx, qjs::Value* this_val, int argc, qjs::Value* args, void* opaque, qjs::Value* out
) @local
{
	JsRuntime* self = (JsRuntime*)opaque;
	qjs::Context js = qjs::wrap(ctx);

	collision::Rigidbody* rigid = pushable(self, &js, argc, args, out, "three.physics.setAngularVelocity");
	if (rigid == null) return;

	rigid.angular_velocity = {
		arg_float(&js, argc, args, 2), arg_float(&js, argc, args, 3), arg_float(&js, argc, args, 4)
	};
}

<*
 `physicsImpulse(index, generation, x, y, z, px, py, pz)` — a push, in
 mass-times-velocity, at an offset from the body's centre.

 **The offset is what makes it spin.** `apply_impulse` splits into a linear term
 scaled by the inverse mass and an angular one from `point.cross(impulse)`, so an
 offset of zero is a pure shove and an offset out at the rim is a shove that also
 tumbles the thing. The prelude passes zero when the script gave no point, so
 there is one verb here rather than two that differ by a cross product.

 The offset is relative to the body's centre and in world axes — not a world
 position, which would be the same numbers meaning something completely
 different for anything not sitting at the origin.
*>
fn void js_physics_impulse(
	qjs::ContextRef ctx, qjs::Value* this_val, int argc, qjs::Value* args, void* opaque, qjs::Value* out
) @local
{
	JsRuntime* self = (JsRuntime*)opaque;
	qjs::Context js = qjs::wrap(ctx);

	collision::Rigidbody* rigid = pushable(self, &js, argc, args, out, "three.physics.applyImpulse");
	if (rigid == null) return;

	Vec3 impulse = {
		arg_float(&js, argc, args, 2), arg_float(&js, argc, args, 3), arg_float(&js, argc, args, 4)
	};
	Vec3 point = {
		arg_float(&js, argc, args, 5), arg_float(&js, argc, args, 6), arg_float(&js, argc, args, 7)
	};

	if (point.length_sq() == 0.0f)
	{
		rigid.apply_linear_impulse(impulse);
		return;
	}
	rigid.apply_impulse(impulse, point);
}

<*
 `physicsTorqueImpulse(index, generation, x, y, z)` — a spin with no shove.

 Separate from the offset form of `physicsImpulse` because "make this rotate" and
 "hit this off-centre" are different intentions, and expressing the first as the
 second means solving for an offset and a force that produce a wanted spin —
 arithmetic nobody should have to do to turn a wheel.
*>
fn void js_physics_torque_impulse(
	qjs::ContextRef ctx, qjs::Value* this_val, int argc, qjs::Value* args, void* opaque, qjs::Value* out
) @local
{
	JsRuntime* self = (JsRuntime*)opaque;
	qjs::Context js = qjs::wrap(ctx);

	collision::Rigidbody* rigid = pushable(self, &js, argc, args, out, "three.physics.applyTorqueImpulse");
	if (rigid == null) return;

	rigid.apply_angular_impulse({
		arg_float(&js, argc, args, 2), arg_float(&js, argc, args, 3), arg_float(&js, argc, args, 4)
	});
}

fn void js_physics_count(
	qjs::ContextRef ctx, qjs::Value* this_val, int argc, qjs::Value* args, void* opaque, qjs::Value* out
) @local
{
	JsRuntime* self = (JsRuntime*)opaque;
	*out = qjs::int_value((int)self.physics.bodies.len());
}

// ---------------------------------------------------------------------------
// The handlers — G5/S7, on the keyboard's machinery.

<*
 `onTrigger(fn)` / `onContact(fn)`, or null to unbind.

 One handler each, replaced rather than stacked, exactly as `onClick` is. Two
 verbs rather than four (`onTriggerEnter`, `onTriggerExit`, …) because the event
 already carries which it is and a script that wants one writes one `if` —
 whereas four registrations is four things to unbind and four to forget.
*>
fn void js_on_trigger(
	qjs::ContextRef ctx, qjs::Value* this_val, int argc, qjs::Value* args, void* opaque, qjs::Value* out
) @local
{
	JsRuntime* self = (JsRuntime*)opaque;
	qjs::Context js = qjs::wrap(ctx);

	bool clearing = argc < 1 || args[0].is_undefined() || args[0].is_null();
	if (!clearing && !js.is_function(args[0]))
	{
		*out = js.raise("three.onTrigger(fn) wants a function, or null to unbind");
		return;
	}

	if (self.trigger_active)
	{
		self.js.release(self.trigger_fn);
		self.trigger_active = false;
	}
	if (clearing) return;

	self.trigger_fn = js.retain(args[0]);
	self.trigger_active = true;
}

fn void js_on_contact(
	qjs::ContextRef ctx, qjs::Value* this_val, int argc, qjs::Value* args, void* opaque, qjs::Value* out
) @local
{
	JsRuntime* self = (JsRuntime*)opaque;
	qjs::Context js = qjs::wrap(ctx);

	bool clearing = argc < 1 || args[0].is_undefined() || args[0].is_null();
	if (!clearing && !js.is_function(args[0]))
	{
		*out = js.raise("three.onContact(fn) wants a function, or null to unbind");
		return;
	}

	if (self.contact_active)
	{
		self.js.release(self.contact_fn);
		self.contact_active = false;
	}
	if (clearing) return;

	self.contact_fn = js.retain(args[0]);
	self.contact_active = true;
}

<*
 Let both handlers go. Same rule as `clear_key_handlers` and for the same
 reason: a retained reference released after the context is gone has nothing to
 be released into.
*>
fn void JsRuntime.clear_physics_handlers(&self)
{
	if (self.trigger_active)
	{
		self.js.release(self.trigger_fn);
		self.trigger_active = false;
	}
	if (self.contact_active)
	{
		self.js.release(self.contact_fn);
		self.contact_active = false;
	}
}

fn void JsRuntime.drop_physics_events(&self) => self.physics.drop_events();

<*
 Say when a body left the simulation, rather than letting it vanish.

 An object that stops falling and starts not existing is the kind of thing
 somebody debugs for an hour. Reported through the frame log, which is where an
 agent already looks for what went wrong inside a frame.
*>
fn void JsRuntime.report_diverged_bodies(&self)
{
	sz count = self.physics.diverged.len();
	if (count == 0) return;
	self.physics.diverged.clear();

	self.report_frame_failure(string::tformat(
		"%d object%s left the simulation and had its body removed. A body that starts inside "
		"static geometry is the usual cause: the solver answers a deep overlap with a correction "
		"deep enough to throw it out of the world. Check that nothing is spawned intersecting "
		"the floor or a wall.",
		count, count == 1 ? "" : "s"
	));
}

<*
 Deliver the step's events, and empty the lists either way.

 **Emptied even with no handler bound**, which is what keeps a world stepping
 under a scene nobody is listening to from growing a list forever.
*>
fn void JsRuntime.dispatch_physics_events(&self)
{
	if (self.physics.trigger_events.len() > 0 && self.trigger_active)
	{
		foreach (hit : self.physics.trigger_events)
		{
			if (self.timed_out) break;
			if (!self.call_physics_handler(self.trigger_fn, self.trigger_event_value(hit), "trigger"))
			{
				self.js.release(self.trigger_fn);
				self.trigger_active = false;
				break;
			}
		}
	}

	if (self.physics.contact_events.len() > 0 && self.contact_active)
	{
		foreach (hit : self.physics.contact_events)
		{
			if (self.timed_out) break;
			if (!self.call_physics_handler(self.contact_fn, self.contact_event_value(hit), "contact"))
			{
				self.js.release(self.contact_fn);
				self.contact_active = false;
				break;
			}
		}
	}

	self.physics.drop_events();
}

<*
 `{ type, trigger, other }` — the two objects as node handles the prelude maps
 back, and `null` for one whose node has already gone.
*>
fn qjs::Value JsRuntime.trigger_event_value(&self, TriggerHit hit)
{
	qjs::Value event = self.js.object();
	self.js.set_property(event, "type", self.js.string(hit.entered ? "enter" : "exit"));
	self.js.set_property(event, "trigger", node_handle_or_null(&self.js, hit.trigger));
	self.js.set_property(event, "other", node_handle_or_null(&self.js, hit.other));
	return event;
}

<*
 `{ type, a, b, normal, point }`. `normal` and `point` are the library's and are
 meaningful only on a start, which the docs say rather than this hiding it.
*>
fn qjs::Value JsRuntime.contact_event_value(&self, ContactHit hit)
{
	qjs::Value event = self.js.object();
	self.js.set_property(event, "type", self.js.string(hit.started ? "start" : "end"));
	self.js.set_property(event, "a", node_handle_or_null(&self.js, hit.a));
	self.js.set_property(event, "b", node_handle_or_null(&self.js, hit.b));
	self.js.set_property(event, "normal", vec3_value(&self.js, hit.normal));
	self.js.set_property(event, "point", vec3_value(&self.js, hit.point));
	return event;
}

fn qjs::Value node_handle_or_null(qjs::Context* js, NodeId id) @local
{
	if (!id.is_set()) return qjs::null_value();
	return handle_value(js, id);
}


<*
 Call one handler with one event. False when it must be unbound — it threw, it
 timed out, or it answered with a promise it cannot keep inside a frame.

 The three failures the keyboard and the click handler already treat alike, and
 treated alike here for the same reason: a handler that cannot finish inside a
 frame is not a handler.
*>
fn bool JsRuntime.call_physics_handler(&self, qjs::Value handler, qjs::Value event, String what)
{
	bool kept = true;

	@pool()
	{
		qjs::Value[1] handler_args = { event };
		defer self.js.release(event);

		qjs::Value? answer = self.js.call(handler, qjs::undefined_value(), handler_args[..]);
		if (catch err = answer)
		{
			self.report_frame_failure(self.timed_out
				? self.frame_timeout_message()
				: string::tformat(
					"the %s handler threw and was stopped: %s", what, self.js.exception(tmem)));
			kept = false;
		}
		else
		{
			bool promised = self.is_thenable(answer);
			self.js.release(answer);
			if (promised)
			{
				self.report_frame_failure(string::tformat(
					"the %s handler returned a promise. It has to finish inside the frame, "
					"so it must be synchronous — do the awaiting in a run_script instead", what));
				kept = false;
			}
		}
	};

	return kept;
}
