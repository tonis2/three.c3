<*
 The physics verbs.

 mesh.body = { shape: 'box', mass: 1, friction: 0.5, restitution: 0.2 }
 three.physics.add(mesh)
 three.physics.remove(mesh)
 three.physics.gravity = [0, -9.8, 0]
 three.physics.velocity(mesh)                     // and setVelocity
 three.physics.applyImpulse(mesh, [0, 5, 0])
 three.physics.joint(door, frame, { type: 'hinge', axis: [0, 1, 0] })
 three.physics.soft(jelly, { mass: 2 })
 three.onTrigger(e => ...)
 three.onContact(e => ...)

 Velocity and impulse are what make a character possible: without them no
 combination of the verbs above both walks and collides — a dynamic body can be
 dropped and watched but never steered, and a kinematic one is steered but never
 stopped.

 Events reuse the keyboard's machinery, which is the whole of this file's second
 half: same registration shape, same "a handler that throws is stopped for good"
 policy, same frame log. A solver event and a keypress are the same kind of thing
 from a script's side — something that happened, delivered once, inside the frame.

 The solver owns a dynamic body's transform, and the refusal for that lives in
 `bind_scene.c3` where the writes arrive rather than here.
*>
module three;

import std::collections::object;
import std::core::string;
import collision;
import fastjs::js;
import std::math::vector;

fn void? JsRuntime.bind_physics_verbs(&self, js::Value host)
{
	self.js.@bind(host, "physicsAdd", &js_physics_add, self)!;
	self.js.@bind(host, "physicsRemove", &js_physics_remove, self)!;
	self.js.@bind(host, "physicsGravitySet", &js_physics_gravity_set, self)!;
	self.js.@bind(host, "physicsGravityGet", &js_physics_gravity_get, self)!;
	self.js.@bind(host, "physicsCount", &js_physics_count, self)!;
	self.js.@bind(host, "physicsTransform", &js_physics_transform, self)!;
	self.js.@bind(host, "physicsVelocityGet", &js_physics_velocity_get, self)!;
	self.js.@bind(host, "physicsLinearSet", &js_physics_linear_set, self)!;
	self.js.@bind(host, "physicsAngularSet", &js_physics_angular_set, self)!;
	self.js.@bind(host, "physicsImpulse", &js_physics_impulse, self)!;
	self.js.@bind(host, "physicsTorqueImpulse", &js_physics_torque_impulse, self)!;
	self.js.@bind(host, "physicsJoint", &js_physics_joint, self)!;
	self.js.@bind(host, "physicsJointRemove", &js_physics_joint_remove, self)!;
	self.js.@bind(host, "physicsSoftAdd", &js_physics_soft_add, self)!;
	self.js.@bind(host, "physicsSoftRemove", &js_physics_soft_remove, self)!;
	self.js.@bind(host, "physicsSoftCount", &js_physics_soft_count, self)!;
	self.js.@bind(host, "physicsSoftPoints", &js_physics_soft_points, self)!;
	self.js.@bind(host, "physicsSoftPin", &js_physics_soft_pin, self)!;
	self.js.@bind(host, "physicsSoftUnpin", &js_physics_soft_unpin, self)!;
	self.js.@bind(host, "onTrigger", &js_on_trigger, self)!;
	self.js.@bind(host, "onContact", &js_on_contact, self)!;
}

<*
 The scene a scene id names, for the verbs about a whole scene rather than a
 node in one.

 @return? js::THREW
*>
fn Scene*? physics_scene(JsRuntime* self, uint id) @local
{
	Scene* found = self.pass == null ? null : self.pass.scene_by_id(id);
	if (found == null)
	{
		return self.js.fail("that Scene was disposed — its objects, its bodies and its nav bake are gone")~;
	}
	return found;
}

<*
 `physicsAdd(node, kind, shape, mass, friction, restitution,
 gravityFactor, linearDamping, angularDamping)`.

 The last three are glTF's `motion`, and they default to this engine's own — all
 of gravity and no damping — for every caller that says nothing about them.

 Strings for the two enums rather than numbers, because they cross once per body
 and a script that mistypes one should be told which word was wrong rather than
 handed body 7 of a scene it did not build.
*>
fn void? js_physics_add(
	JsRuntime* self,
	NodeRef ref,
	String kind_name,
	String shape_name,
	float mass,
	float friction,
	float restitution,
	Opt {float} gravity_factor,
	Opt {float} linear_damping,
	Opt {float} angular_damping
)
{
	BodyKind kind;
	switch (kind_name)
	{
		case "dynamic": kind = BodyKind.DYNAMIC;
		case "static": kind = BodyKind.STATIC;
		case "kinematic": kind = BodyKind.KINEMATIC;
		case "trigger": kind = BodyKind.TRIGGER;
		default:
			return self.js.fail("'%s' is not a body kind — it is one of dynamic, static, kinematic or trigger",
				kind_name)~;
	}

	ColliderShape shape;
	switch (shape_name)
	{
		case "box": shape = ColliderShape.BOX;
		case "sphere": shape = ColliderShape.SPHERE;
		case "capsule": shape = ColliderShape.CAPSULE;
		case "hull": shape = ColliderShape.HULL;
		case "heightfield": shape = ColliderShape.HEIGHTFIELD;
		default:
			return self.js.fail("'%s' is not a collider shape — it is one of box, sphere, capsule, hull or heightfield",
				shape_name)~;
	}

	// The scene the object is in, not the one being rendered: bodies for the
	// next level are built while it is still off screen, which is most of what
	// owning a world per scene is for.
	if (catch err = ref.scene.physics.add(
		ref.scene,
		&self.pass.assets,
		ref.id,
		kind,
		shape,
		mass,
		friction,
		restitution,
		gravity_factor.or(1.0f),
		linear_damping.or(0),
		angular_damping.or(0)
	))
	{
		return self.js.fail("%s", physics_add_message(err, shape_name))~;
	}
}

<*
 A sentence for each way `Physics.add` refuses, rather than the fault's name.

 Each of these is a thing a script did, and each has a different next step —
 which is the reason they are separate faults and not one.
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
		case NODE_IS_NOT_TERRAIN:
			return "a 'heightfield' collider is the terrain's own grid of heights, and this mesh "
				"has none — build it with new three.TerrainGeometry(field), or use 'hull'";
		default:
			return string::tformat("the body could not be added: %s", err);
	}
}

<*
 `physicsRemove(node)` — true when there was one.
*>
fn bool js_physics_remove(JsRuntime* self, NodeRef ref) => ref.scene.physics.remove(ref.id);

fn void? js_physics_gravity_set(JsRuntime* self, uint scene_id, Vec3 gravity)
{
	physics_scene(self, scene_id)!.physics.set_gravity(gravity);
}

fn Vec3? js_physics_gravity_get(JsRuntime* self, uint scene_id)
{
	Scene* scene = physics_scene(self, scene_id)!;
	// Reported before the world is opened too, so reading gravity is not the thing
	// that creates a world.
	return scene.physics.opened ? scene.physics.world.gravity : PHYSICS_GRAVITY;
}

<*
 `physicsTransform(node)` — where the solver has put a node, as
 `{ position, rotation }`.

 The read-back door, and the only one there is. `prelude.js` holds a node's
 transform as JavaScript numbers and pushes them on write, which is right while a
 script is the only writer — and leaves `mesh.position` reporting where a script
 last put a falling body rather than where it fell to. So a solver-owned object
 refreshes through here before it answers.

 Euler rather than the quaternion the node stores, because `rotation` is an Euler
 triple on the JavaScript side and `euler_from_quat` is already the one place that
 converts backwards for exactly this reason.
*>
fn SolverPose js_physics_transform(JsRuntime* self, NodeRef ref)
{
	Node* node = ref.scene.node(ref.id);
	return { .position = node.position, .rotation = euler_from_quat(node.rotation) };
}

// Where the solver put a node: its position, and its rotation as Euler angles.
struct SolverPose
{
	Vec3 position;
	Vec3 rotation;
}

// ---------------------------------------------------------------------------
// Velocity and impulse
// 
// Five verbs over three solver calls. What they share is the guard: each one
// resolves the node, refuses a body the solver does not integrate, and wakes the
// island before touching anything. Skipping the wake is the failure worth naming
// twice — a sleeping body absorbs an impulse into a number nothing reads, so the
// same line of script works on a rolling crate and does nothing at all to a
// settled one.

<*
 Resolves a node to a body that may be pushed, or raises saying why not.

 Three different refusals rather than one, because they are three different
 mistakes and the fix for each is a different line of script.
*>
fn collision::Rigidbody*? pushable(JsRuntime* self, NodeRef ref, String verb) @local
{
	NodeId id = ref.id;

	PhysicsBody* body = ref.scene.physics.body_for(id);
	if (body == null)
	{
		return self.js.fail("%s needs a body — three.physics.add(object) first", verb)~;
	}
	if (body.kind == BodyKind.STATIC)
	{
		return self.js.fail("%s cannot move a static body: its inverse mass is zero, so an impulse is arithmetically nothing. Give it a mass, or move its transform directly",
			verb)~;
	}
	if (body.kind == BodyKind.KINEMATIC)
	{
		return self.js.fail("%s cannot move a kinematic body: the solver drives it from the transform your script writes, so a velocity set here is discarded a fraction of a step later. Move object.position instead",
			verb)~;
	}
	if (body.kind == BodyKind.TRIGGER)
	{
		return self.js.fail("%s cannot move a trigger: a trigger detects overlaps and is never integrated", verb)~;
	}

	collision::Rigidbody* rigid = ref.scene.physics.rigidbody_for(id);
	if (rigid == null)
	{
		return self.js.fail("%s found the body's record but not the solver's, which should not happen", verb)~;
	}
	ref.scene.physics.wake(rigid);
	return rigid;
}

<*
 `physicsVelocityGet(node)` — `[lx, ly, lz, ax, ay, az]`, or null.

 Null rather than a raise for `physicsTransform`'s reason: a getter is asked in a
 loop over things that may or may not have bodies, and making that a throw would
 mean writing the check twice in every such loop.

 Both velocities in one array, because a script that
 wants one usually wants the other in the same breath — a character reads linear
 to decide whether it is moving and angular to decide whether it has been spun.

 Answers for every kind of body, unlike the setters. Reading a kinematic body's
 velocity is how a script finds out how fast the transform it is writing is
 actually carrying the thing.
*>
fn js::Value? js_physics_velocity_get(JsRuntime* self, NodeRef ref)
{
	collision::Rigidbody* rigid = ref.scene.physics.rigidbody_for(ref.id);
	if (rigid == null) return js::NULL;

	return self.js.numbers({
		rigid.linear_velocity.x, rigid.linear_velocity.y, rigid.linear_velocity.z,
		rigid.angular_velocity.x, rigid.angular_velocity.y, rigid.angular_velocity.z,
	});
}

<*
 `physicsLinearSet(node, x, y, z)` — units per second, world space.

 Assignment, not addition, and that is the difference from an impulse that
 matters at a call site. A character sets its velocity every frame from the keys
 that are down, because what it wants is a speed; an explosion applies an
 impulse, because what it wants is a change to whatever the speed already was.
 Getting this backwards gives a character that accelerates forever.

 The solver reconstructs `linear_velocity` from the position delta at the end of
 every step, so what is written here survives exactly one integration and then
 becomes whatever actually happened — which is why a character sets it again next
 frame rather than once.
*>
fn void? js_physics_linear_set(JsRuntime* self, NodeRef ref, Vec3 velocity)
{
	pushable(self, ref, "three.physics.setVelocity")!.linear_velocity = velocity;
}

<*
 `physicsAngularSet(node, x, y, z)` — radians per second about each
 world axis, the vector's length being the rate.
*>
fn void? js_physics_angular_set(JsRuntime* self, NodeRef ref, Vec3 velocity)
{
	pushable(self, ref, "three.physics.setAngularVelocity")!.angular_velocity = velocity;
}

<*
 `physicsImpulse(node, x, y, z, px, py, pz)` — a push, in
 mass-times-velocity, at an offset from the body's centre.

 The offset is what makes it spin. `apply_impulse` splits into a linear term
 scaled by the inverse mass and an angular one from `point.cross(impulse)`, so an
 offset of zero is a pure shove and an offset out at the rim is a shove that also
 tumbles the thing. The prelude passes zero when the script gave no point, so
 there is one verb here rather than two that differ by a cross product.

 The offset is relative to the body's centre and in world axes — not a world
 position, which would be the same numbers meaning something completely different
 for anything not sitting at the origin.
*>
fn void? js_physics_impulse(JsRuntime* self, NodeRef ref, Vec3 impulse, Vec3 point)
{
	collision::Rigidbody* rigid = pushable(self, ref, "three.physics.applyImpulse")!;
	if (point.length_sq() == 0.0f)
	{
		rigid.apply_linear_impulse(impulse);
		return;
	}
	rigid.apply_impulse(impulse, point);
}

<*
 `physicsTorqueImpulse(node, x, y, z)` — a spin with no shove.

 Separate from the offset form of `physicsImpulse` because "make this rotate" and
 "hit this off-centre" are different intentions, and expressing the first as the
 second means solving for an offset and a force that produce a wanted spin.
*>
fn void? js_physics_torque_impulse(JsRuntime* self, NodeRef ref, Vec3 impulse)
{
	pushable(self, ref, "three.physics.applyTorqueImpulse")!.apply_angular_impulse(impulse);
}

fn int? js_physics_count(JsRuntime* self, uint scene_id) => (int)physics_scene(self, scene_id)!.physics.bodies.len();

// ---------------------------------------------------------------------------
// Joints
// 
// The host takes a **limit list** and nothing else: a joint is some of the joint
// frame's axes held to some range, which is glTF's `KHR_physics_rigid_bodies`
// description of one and is exactly the two lists `collision::GenericJoint3D`
// carries. The four familiar words — fixed, point, hinge, slider — are shorthand
// that `prelude/physics.js` expands before it calls, so nothing here knows what a
// hinge is and a limit read out of a file needs no translation to be passed in.

// Six floats per limit: kind, axes, min, max, stiffness, damping. Named here and
// in `prelude/physics.js`, which is the only other place that knows the layout.
const sz JOINT_LIMIT_FLOATS = 6;

<*
 `physicsJoint(a, b, hasPivot, px, py, pz, ax, ay, az, collide, stiffness, damping, limits)`.

 `limits` is a `Float32Array` of six numbers per limit —
 `kind, axes, min, max, stiffness, damping` — rather than an options array read
 back one property at a time. The shape of it is written down in
 `prelude/physics.js` where it is filled in.
*>
fn int? js_physics_joint(
	JsRuntime* self,
	NodeRef a,
	NodeRef b,
	bool has_pivot,
	Vec3 pivot,
	Vec3 axis,
	bool collide,
	float stiffness,
	float damping,
	float[] packed
)
{
	if (a.scene != b.scene)
	{
		return self.js.fail(
			"three.physics.joint needs both objects in the same scene — a world belongs to a scene, "
				"and a joint is a constraint inside one world"
		)~;
	}

	if (packed.len == 0 || packed.len % JOINT_LIMIT_FLOATS != 0)
	{
		return self.js.fail("three.physics.joint needs at least one limit")~;
	}

	@pool()
	{
		sz count            = packed.len / JOINT_LIMIT_FLOATS;
		JointLimit[] limits = alloc::new_array(tmem, JointLimit, count);
		for (sz i = 0; i < count; i++)
		{
			float[] row = packed[i * JOINT_LIMIT_FLOATS..][:JOINT_LIMIT_FLOATS];
			limits[i] = {
				.angular = row[0] != 0,
				.axes = (char)row[1],
				.min = row[2],
				.max = row[3],
				.stiffness = row[4],
				.damping = row[5],
			};
		}

		JointSpec spec = {
			.has_pivot = has_pivot,
			.pivot = pivot,
			.axis = axis,
			.collide = collide,
			.stiffness = stiffness,
			.damping = damping,
			.limits = limits,
		};

		sz? id = a.scene.physics.add_joint(a.id, b.id, spec);
		if (catch err = id) return self.js.fail("%s", joint_message(err))~;
		return (int)id;
	};
}

<*
 A sentence for each way `Physics.add_joint` refuses, rather than the fault's
 name. Each of these is a different thing a script did.
*>
fn String joint_message(fault err) @local
{
	switch (err)
	{
		case JOINT_NEEDS_A_BODY:
			return "a joint holds two bodies together and one of these objects has none — "
				"three.physics.add(object) on both first";
		case JOINT_ON_ONE_BODY:
			return "a joint needs two different objects; this one is joined to itself";
		case JOINT_ON_A_TRIGGER:
			return "a trigger detects overlaps and is never integrated, so a joint could not move it";
		case JOINT_NEEDS_A_MOVER:
			return "neither end of this joint can move — a static body's inverse mass is zero and a "
				"kinematic one is driven by your script, so there is nothing for the constraint to "
				"solve. Give one of them a mass";
		case JOINT_HAS_NO_LIMITS:
			return "a joint with no limits holds nothing — give it a type, or limits of your own";
		case JOINT_HAS_TOO_MANY_LIMITS:
			return "more than three limits on one side of this joint, and there are only three axes "
				"to hold — an axis is named twice";
		default:
			return string::tformat("the joint could not be made: %s", err);
	}
}

<*
 `physicsJointRemove(sceneId, id)` — true when there was one.

 The scene crosses explicitly, unlike everywhere else here: a joint is not a node,
 so there is no handle to find its world from.
*>
fn bool? js_physics_joint_remove(JsRuntime* self, uint scene_id, int id)
{
	return physics_scene(self, scene_id)!.physics.remove_joint((sz)id);
}

// ---------------------------------------------------------------------------
// Soft bodies

<*
 `physicsSoftAdd(node, mass, softness, damping, volume, volumeSoftness, bending, bendingSoftness, friction,
 restitution)`.
*>
fn void? js_physics_soft_add(
	JsRuntime* self,
	NodeRef ref,
	float mass,
	float softness,
	float damping,
	bool volume,
	float volume_softness,
	bool bending,
	float bending_softness,
	float friction,
	float restitution
)
{
	SoftSpec spec = {
		.mass = mass,
		.softness = softness,
		.damping = damping,
		.volume = volume,
		.volume_softness = volume_softness,
		.bending = bending,
		.bending_softness = bending_softness,
		.friction = friction,
		.restitution = restitution,
	};

	if (catch err = ref.scene.physics.add_soft(ref.scene, &self.pass.assets, ref.id, spec))
	{
		return self.js.fail("%s", soft_message(err))~;
	}
}

<*
 A sentence for each way `Physics.add_soft` refuses. The two it shares with
 `physicsAdd` mean the same thing there and are fixed the same way.
*>
fn String soft_message(fault err) @local
{
	switch (err)
	{
		case NODE_HAS_NO_MESH:
			return "a soft body is a mesh's own vertices, and this object draws nothing — "
				"give it to a mesh rather than to a group";
		case NODE_IS_NOT_TOP_LEVEL:
			return "a soft body has to be a child of the scene, not of another object — "
				"its particles are world space and a parent transform would fight them";
		case SOFT_IS_SKINNED:
			return "a skinned mesh's vertices already belong to its skeleton, so a soft body "
				"cannot have them as well — soft-body a prop, and animate a character";
		case SOFT_HAS_NO_POINTS:
			return "this mesh's points never reached the host, so there is nothing to make "
				"particles out of — it may not have been drawn yet";
		default:
			return string::tformat("the soft body could not be made: %s", err);
	}
}

<*
 `physicsSoftRemove(node)` — true when there was one.
*>
fn bool js_physics_soft_remove(JsRuntime* self, NodeRef ref) => ref.scene.physics.remove_soft(ref.id);

<*
 `physicsSoftCount(node)` — how many particles, and 0 for a node with
 no soft body.
*>
fn int js_physics_soft_count(JsRuntime* self, NodeRef ref) => (int)ref.scene.physics.soft_points(ref.id).len;

<*
 `physicsSoftPoints(node, into)` — the particles, in world space,
 copied into a script-owned `Float32Array` of exactly `count * 3` floats.

 Filled rather than answered, which is `texture.read(into)`'s arrangement and for
 the same two reasons: a script watching a soft body every frame reuses one array
 instead of allocating one, and handing back a view onto the solver's own list
 would be a pointer into storage its next push moves.

 Answers how many particles were written, and 0 when the array is the wrong size.
*>
fn int js_physics_soft_points(JsRuntime* self, NodeRef ref, float[] into)
{
	Vec3[] points = ref.scene.physics.soft_points(ref.id);
	if (points.len == 0) return 0;
	if (into.len * float::size != points.len * Vec3::size) return 0;

	mem::copy(into.ptr, points.ptr, into.len * float::size);
	return (int)points.len;
}

<*
 `physicsSoftPin(node, particle, hasAt, x, y, z)` — hold one particle
 at a world point, or where it already is.
*>
fn bool js_physics_soft_pin(JsRuntime* self, NodeRef ref, int particle, bool has_at, Vec3 at)
{
	Vec3[] points = ref.scene.physics.soft_points(ref.id);
	if (particle < 0 || particle >= points.len) return false;
	return ref.scene.physics.pin_soft(ref.id, (sz)particle, has_at ? at : points[particle]);
}

<*
 `physicsSoftUnpin(node, particle, mass)` — let one particle go.
*>
fn bool js_physics_soft_unpin(JsRuntime* self, NodeRef ref, int particle, float mass)
{
	return ref.scene.physics.unpin_soft(ref.id, (sz)particle, mass);
}

// ---------------------------------------------------------------------------
// The handlers, on the keyboard's machinery.

<*
 `onTrigger(fn)` / `onContact(fn)`, or null to unbind.

 One handler each, replaced rather than stacked, exactly as `onClick` is. Two
 verbs rather than four (`onTriggerEnter`, `onTriggerExit`, …) because the event
 already carries which it is and a script that wants one writes one `if` —
 whereas four registrations is four things to unbind and four to forget.
*>
fn void? js_on_trigger(JsRuntime* self, js::Value f)
{
	bool clearing = f.is_nullish();
	if (!clearing && !f.is_function())
	{
		return self.js.fail("three.onTrigger(fn) wants a function, or null to unbind")~;
	}

	self.trigger_handler.release(self.js);
	if (clearing) return;
	self.trigger_handler.hold(self.js, f);
}

fn void? js_on_contact(JsRuntime* self, js::Value f)
{
	bool clearing = f.is_nullish();
	if (!clearing && !f.is_function())
	{
		return self.js.fail("three.onContact(fn) wants a function, or null to unbind")~;
	}

	self.contact_handler.release(self.js);
	if (clearing) return;
	self.contact_handler.hold(self.js, f);
}

<*
 Lets both handlers go. Same rule as `clear_key_handlers`: before the context
 goes, never after.
*>
fn void JsRuntime.clear_physics_handlers(&self)
{
	self.trigger_handler.release(self.js);
	self.contact_handler.release(self.js);
}

// The rendered scene's, in all three of these: they are the frame's half of
// physics, and the frame steps one world — see `Scene.physics`.
fn void JsRuntime.drop_physics_events(&self) => self.pass.scene.physics.drop_events();

<*
 Says when a body left the simulation, rather than letting it vanish.

 An object that stops falling and starts not existing is the kind of thing
 somebody debugs for an hour. Reported through the frame log, where an agent
 already looks for what went wrong inside a frame.
*>
fn void JsRuntime.report_diverged_bodies(&self)
{
	sz count = self.pass.scene.physics.diverged.len();
	if (count == 0) return;
	self.pass.scene.physics.diverged.clear();

	self.report_frame_failure(
		string::tformat(
			"%d object%s left the simulation and had its body removed. A body that starts inside "
				"static geometry is the usual cause: the solver answers a deep overlap with a correction "
				"deep enough to throw it out of the world. Check that nothing is spawned intersecting "
				"the floor or a wall.",
			count,
			count == 1 ? "" : "s"
		)
	);
}

<*
 Delivers the step's events, and empties the lists either way.

 Emptied even with no handler bound, which is what keeps a world stepping under a
 scene nobody is listening to from growing a list forever.
*>
fn void JsRuntime.dispatch_physics_events(&self)
{
	if (self.pass.scene.physics.trigger_events.len() > 0 && self.trigger_handler.active)
	{
		foreach (hit : self.pass.scene.physics.trigger_events)
		{
			if (self.timed_out) break;
			ScriptTriggerEvent event = {
				.type = hit.entered ? "enter" : "exit",
				.trigger = self.live_node(hit.trigger),
				.other = self.live_node(hit.other),
			};
			// Building the event fails only out of memory; that event is lost, the handler is not.
			js::Value? value = self.js.@object_of(event);
			if (catch value)
			{
				self.js.take_exception();
				continue;
			}
			if (!self.call_physics_handler(self.trigger_handler.get(self.js), value, "trigger"))
			{
				self.trigger_handler.release(self.js);
				break;
			}
		}
	}

	if (self.pass.scene.physics.contact_events.len() > 0 && self.contact_handler.active)
	{
		foreach (hit : self.pass.scene.physics.contact_events)
		{
			if (self.timed_out) break;
			ScriptContactEvent event = {
				.type = hit.started ? "start" : "end",
				.a = self.live_node(hit.a),
				.b = self.live_node(hit.b),
				.normal = hit.normal,
				.point = hit.point,
			};
			js::Value? value = self.js.@object_of(event);
			if (catch value)
			{
				self.js.take_exception();
				continue;
			}
			if (!self.call_physics_handler(self.contact_handler.get(self.js), value, "contact"))
			{
				self.contact_handler.release(self.js);
				break;
			}
		}
	}

	self.pass.scene.physics.drop_events();
}

<*
 `{ type, trigger, other }`, the two objects as Node handles, and `null` for one
 whose node has already gone.
*>
struct ScriptTriggerEvent
{
	String type;
	NodeId trigger;
	NodeId other;
}

<*
 `{ type, a, b, normal, point }`. `normal` and `point` are the library's and are
 meaningful only on a start, which the docs say rather than this hiding it.
*>
struct ScriptContactEvent
{
	String type;
	NodeId a;
	NodeId b;
	Vec3 normal;
	Vec3 point;
}

// The id while its node lives, so an event names a removed node as null.
fn NodeId JsRuntime.live_node(&self, NodeId id) => id.is_set() && self.find_node(id).scene ? id : NO_NODE;

<*
 Calls one handler with one event. False when it must be unbound — it threw, it
 timed out, or it answered with a promise it cannot keep inside a frame.

 The three failures the keyboard and the click handler already treat alike, and
 treated alike here for the same reason: a handler that cannot finish inside a
 frame is not a handler.
*>
fn bool JsRuntime.call_physics_handler(&self, js::Value handler, js::Value event, String what)
{
	@pool()
	{
		return self.call_handler(handler, { event }, string::tformat("the %s handler", what));
	};
}
