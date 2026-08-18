<*
 The physics verbs — `game.md` G5/S3, S6, S7.

	mesh.body = { shape: 'box', mass: 1, friction: 0.5, restitution: 0.2 }
	three.physics.add(mesh)
	three.physics.remove(mesh)
	three.physics.gravity = [0, -9.8, 0]
	three.onTrigger(e => ...)
	three.onContact(e => ...)

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
