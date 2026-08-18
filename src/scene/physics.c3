<*
 The physics world — `game.md` G5.

 **The solver was already written.** `lib/collision.c3l/src/solver/` is XPBD with
 GJK/EPA, spatial hashing, islands, sleeping, joints, triggers and contacts. This
 file is a binding and a set of decisions, and the decisions are the part worth
 reading.

 **Fixed step, in C3.** The world runs at a fixed 60 Hz behind an accumulator
 kept here rather than in JavaScript (G5/S1). That is the answer to
 `event_loop.md`'s "no fixed timestep, no interpolation": physics is fixed-rate,
 the frame callback stays variable-rate, and the two never argue. An accumulator
 written in JS would run inside the script budget, so a spiral of death would
 trip the budget and stop the callback for good rather than merely stutter.

 **Y-up, with no swizzle anywhere.** `collision.c3l` defaults to z-down gravity
 and still does for everyone else; three.c3 sets `{0, -9.8, 0}` once, here, and
 nothing converts between the two conventions at any boundary. That is only
 possible because the solver stopped reading a fixed component of gravity —
 `resolver.c3`'s `impulse_dir` and `GroundPlane`, changed for this milestone.
 A conversion at the seam would have meant two conventions meeting inside the
 two functions nobody reads twice.

 **The solver owns a dynamic body's transform** (G5/S6). The camera resolves a
 script and a drag by last-writer-wins, and that is right there because both are
 describing the same intent. It is wrong here: a solver and a script both writing
 a transform every frame produce jitter, not a compromise. So a JS write to a
 dynamic body's position or rotation is refused with a sentence, and a body that
 wants to be driven is kinematic — which is what "I want to move this myself"
 actually means.

 **World space, so a body-backed node hangs off the root.** The solver works in
 world space and writes back into a node's *local* transform, which are the same
 thing only when the parent is the scene root. Rather than silently writing a
 world transform into a nested node's local slot, `add` refuses and says so.
*>
module three;

import std::collections::list;
import std::math;
import std::math::vector;
import std::math::quaternion;
import collision;
import std::io;

faultdef
	// The node draws nothing, so there is no size to take a collider from.
	NODE_HAS_NO_MESH,
	// A hull was asked for on a mesh whose positions never reached the host.
	MESH_HAS_NO_HULL,
	// The solver works in world space; a nested node's local transform is not.
	NODE_IS_NOT_TOP_LEVEL;

// What a script is told when it writes a transform the solver owns. One string
// rather than two copies, because it is raised from both transform doors and a
// sentence that drifts between them is worse than no sentence.
const String PHYSICS_OWNS_TRANSFORM =
	"this object's transform belongs to the physics solver — a dynamic body is "
	"moved by the world, not by a script. Make the body kinematic to drive it "
	"yourself, or three.physics.remove(object) first.";

// The fixed tick. Not a setting: two worlds stepped at different rates are two
// different simulations, and the determinism `PhysicsWorld.state_hash` offers
// is worth more than a knob.
const double PHYSICS_STEP_MS = 1000.0 / 60.0;

// The most steps one frame may run to catch up. Past this the backlog is
// dropped rather than run, which is the whole difference between a stutter and
// a spiral: every frame that ran long would otherwise ask the next one to run
// longer still.
const int PHYSICS_MAX_STEPS = 5;

// How far a body may get from the origin before it is treated as lost rather
// than merely falling. Ten kilometres of world units: past anything a scene
// means, and well short of where float precision stops describing a position.
const float DIVERGED_DISTANCE_SQ = 10_000.0f * 10_000.0f;

// Y-up. See the header — this is the only place a gravity direction is chosen.
const Vec3 PHYSICS_GRAVITY = { 0, -9.8, 0 };

enum BodyKind : char
{
	DYNAMIC,
	STATIC,
	KINEMATIC,
	TRIGGER,
}

enum ColliderShape : char
{
	BOX,
	SPHERE,
	CAPSULE,
	HULL,
}

<*
 One body, and the node it moves.
*>
struct PhysicsBody
{
	NodeId node;
	sz id;
	BodyKind kind;
	ColliderShape shape;

	// The collider, on the heap and owned here.
	//
	// **The address is the point.** `TransformedShape.shape` is an interface
	// value pointing straight at this allocation, so a `List` of shapes that
	// reallocated on its next push would leave every body already in the world
	// pointing into freed memory. One allocation per body, released in `drop`.
	void* collider;
}

<*
 Give back the one allocation a body owns.

 Typed on the way out because a `collision::Mesh` has lists of its own and
 `mem::free` on the outer pointer would leak both of them.
*>
fn void PhysicsBody.drop(&self)
{
	if (self.collider == null) return;

	if (self.shape == ColliderShape.HULL)
	{
		collision::Mesh* mesh = (collision::Mesh*)self.collider;
		mesh.free();
	}
	mem::free(self.collider);
	self.collider = null;
}

<*
 A trigger overlap starting or ending, in the terms a script thinks in.

 **Nodes rather than body ids, resolved here rather than at dispatch.** The
 whole point of `remove_body` emitting EXIT is that a body destroyed inside a
 trigger is still seen to leave it — and by the time the handler runs, that body
 is gone from `bodies` and its id resolves to nothing. Whatever a script is told
 has to be captured while the body still exists.
*>
struct TriggerHit
{
	NodeId trigger;
	NodeId other;
	bool entered;
}

<*
 Two bodies touching or coming apart. `normal` and `point` mean something only
 on a start, which is the library's rule and is repeated in the doc the prelude
 hands out rather than papered over here.
*>
struct ContactHit
{
	NodeId a;
	NodeId b;
	bool started;
	Vec3 normal;
	Vec3 point;
}

struct Physics
{
	collision::PhysicsWorld world;
	List{PhysicsBody} bodies;

	sz next_id;
	double accumulator_ms;

	// Drained off the world after every step *and* after every removal, and
	// emptied by the dispatch in `js/bind_physics.c3`.
	//
	// Held here rather than read straight off the world because `run_step`
	// clears the world's own lists at the top: a body removed between frames
	// would otherwise have its EXIT events wiped before anything saw them.
	List{TriggerHit} trigger_events;
	List{ContactHit} contact_events;

	// Bodies the solver lost control of, taken out of the world and waiting to
	// be reported. See `Physics.evict_diverged`.
	List{NodeId} diverged;

	bool opened;
}

fn void Physics.open(&self)
{
	if (self.opened) return;
	self.world = collision::DEFAULT_PHYSICS_WORLD;
	// **On the heap, explicitly.** A zero-valued C3 map or list initializes
	// itself into the *temp* allocator on first use, and a world that outlives
	// a frame cannot have its storage in a pool that is released at the end of
	// one. Measured the hard way: it crashes inside a hash table, several
	// frames from anything that mentions physics.
	self.world.init(mem);
	self.world.gravity = PHYSICS_GRAVITY;

	// **And this side's lists too, for the same reason.** A bare C3 list binds
	// itself to the temp allocator on its first push, so `bodies` would live in
	// whichever frame's pool happened to be open when the first body was added
	// and be freed under the world at the end of it. What that looks like is
	// worth writing down: `len()` keeps answering, because the count is in the
	// struct and only the buffer is gone, so the world goes on stepping while
	// every body reads as garbage and nothing is written back. It looks like
	// physics that runs but does not move anything.
	self.bodies.init(mem);
	self.trigger_events.init(mem);
	self.contact_events.init(mem);
	self.diverged.init(mem);
	// **Single-threaded, deliberately** — `game.md` G5/S8. `plan.md`'s design
	// rests on handlers, scene and device all being touched from one thread, so
	// nothing needs a lock. The solver's pool is confined to the inside of
	// `run_step` and joined before it returns, but a body count that fits in a
	// scene an agent builds is not where a thread pool pays for itself, and one
	// thread is the version whose failure modes are all already understood.
	self.world.thread_count = 1;
	self.next_id = 1;
	self.opened = true;
}

fn void Physics.close(&self)
{
	if (!self.opened) return;
	foreach (&body : self.bodies) body.drop();
	self.bodies.free();
	self.trigger_events.free();
	self.contact_events.free();
	self.diverged.free();
	self.world.free();
	self.opened = false;
	self.accumulator_ms = 0;
}

<*
 The body on a node, or null.

 A linear scan, and the early return is what makes it free: a scene with no
 bodies pays nothing, and that is the common case for the transform-write check
 in `bind_scene.c3` which asks this on every write a script makes.
*>
fn PhysicsBody* Physics.body_for(&self, NodeId node)
{
	if (self.bodies.len() == 0) return null;
	foreach (&body : self.bodies)
	{
		if (body.node == node) return body;
	}
	return null;
}

<*
 Whether a script may write this node's transform.

 False only for a body the solver drives. A static body never moves and a
 kinematic one is *supposed* to be moved — through `set_kinematic_target`, which
 `Physics.drive` calls with whatever the script wrote.
*>
fn bool Physics.owns_transform(&self, NodeId node)
{
	PhysicsBody* body = self.body_for(node);
	if (body == null) return false;
	return body.kind == BodyKind.DYNAMIC;
}

<*
 Build the collider a body will carry, from the mesh the node draws.

 `game.md` G5/S4: the collider comes from the asset. A box and a sphere are the
 mesh's own bounds, which every mesh slot carries from the moment its glTF was
 parsed; a hull is `collision::quickhull` over the positions the picking tree
 already keeps, which is **exactly what `ConvexGeometry` does** — so a convex
 rock's collider is its own geometry, computed by the same function, and is
 exact rather than an approximation of itself.

 Answers null when the node draws nothing, because there is then no size to take
 and guessing one is worse than saying so.

 @param bounds : `Filled with the mesh's local bounds, which the caller needs for the body's centre.`
*>
fn void*? Physics.build_collider(
	&self, Assets* assets, Node* node, ColliderShape shape, collision::Aabb3* bounds
)
{
	if (!node.asset.is_set()) return NODE_HAS_NO_MESH~;

	GpuMesh* slot = assets.mesh(node.asset, node.mesh);
	if (slot == null) return NODE_HAS_NO_MESH~;

	*bounds = slot.bounds;
	Vec3 extent = (slot.bounds.max - slot.bounds.min) * 0.5f;

	switch (shape)
	{
		case BOX:
			collision::Aabb3* box = mem::new(collision::Aabb3);
			*box = slot.bounds;
			return box;

		case SPHERE:
			collision::Sphere* sphere = mem::new(collision::Sphere);
			// The bound's own centre, and the radius that contains it. A sphere
			// inscribed instead would let a corner of the art poke through the
			// floor, which reads as a bug in the solver.
			*sphere = {
				.center = (slot.bounds.min + slot.bounds.max) * 0.5f,
				.radius = math::max(extent.x, math::max(extent.y, extent.z)),
			};
			return sphere;

		case CAPSULE:
			// About +Y, which is `shapes.c3`'s axis and this project's up. The
			// height is the cylindrical section only, matching the library's
			// KHR_implicit_shapes reading, so the caps are what the rest of the
			// bound pays for.
			float radius = math::max(extent.x, extent.z);
			collision::Capsule* capsule = mem::new(collision::Capsule);
			*capsule = {
				.height = math::max(0.0f, (extent.y - radius) * 2.0f),
				.radius_top = radius,
				.radius_bottom = radius,
			};
			return capsule;

		case HULL:
			// `hull_positions` is the picking tree's, and it exists from the
			// mesh's upload — which `scene.add()` triggers, so a node in the
			// scene has one. A mesh that never reached the device has not got
			// one, and a box of the right size beats a hull of nothing.
			if (slot.hull_positions.len == 0) return MESH_HAS_NO_HULL~;

			collision::Mesh hull = collision::quickhull(slot.hull_positions);
			if (hull.vertices.len() == 0)
			{
				hull.free();
				return MESH_HAS_NO_HULL~;
			}
			collision::Mesh* heap = mem::new(collision::Mesh);
			*heap = hull;
			return heap;
	}
}

<*
 Hand the collider to the world as the interface value it wants.

 The cast back is unavoidable: `PhysicsBody` keeps a `void*` because the four
 shapes have four types and one field, and the interface value has to be built
 from the concrete pointer or it carries the wrong vtable.
*>
fn collision::TransformedShape Physics.transformed(&self, PhysicsBody* body, Node* node)
{
	collision::TransformedShape shape = {
		.translation = node.position,
		.scale = node.scale,
		.rotation = node.rotation,
	};

	switch (body.shape)
	{
		case BOX:     shape.shape = (collision::Aabb3*)body.collider;
		case SPHERE:  shape.shape = (collision::Sphere*)body.collider;
		case CAPSULE: shape.shape = (collision::Capsule*)body.collider;
		case HULL:    shape.shape = (collision::Mesh*)body.collider;
	}

	return shape;
}

<*
 Give a node a body.

 Adding twice replaces rather than stacks, which is what a script re-running its
 own setup does and the only behaviour that does not slowly fill the world with
 bodies nothing can name.

 @param mass : `Ignored for anything but a dynamic body — a static one is mass 0 by definition.`
*>
fn void? Physics.add(
	&self, Scene* scene, Assets* assets, NodeId node_id,
	BodyKind kind, ColliderShape shape, float mass, float friction, float restitution
)
{
	self.open();

	Node* node = scene.node(node_id);
	if (node == null) return NODE_HAS_NO_MESH~;

	// World space, so the parent has to be what world space is measured from.
	// See the header: the alternative is writing a world transform into a
	// nested node's local slot every frame and calling the result physics.
	if (!(node.parent == scene.root)) return NODE_IS_NOT_TOP_LEVEL~;

	self.remove(node_id);

	collision::Aabb3 bounds;
	void*? built = self.build_collider(assets, node, shape, &bounds);
	if (catch err = built) return err~;

	PhysicsBody body = {
		.node = node_id,
		.id = self.next_id++,
		.kind = kind,
		.shape = shape,
		.collider = built,
	};

	bool dynamic = kind == BodyKind.DYNAMIC;
	collision::Rigidbody rigid = {
		.id = body.id,
		.collider = self.transformed(&body, node),
		.mass = dynamic ? mass : 0,
		.gravity_factor = dynamic ? 1.0f : 0,
		.is_kinematic = kind == BodyKind.KINEMATIC,
		.can_sleep = dynamic,
		.material = {
			.static_friction = friction,
			.dynamic_friction = friction,
			.restitution = restitution,
		},
	};

	if (kind == BodyKind.TRIGGER)
	{
		if (catch err = self.world.add_trigger(rigid)) { body.drop(); return err~; }
	}
	else
	{
		if (catch err = self.world.add_body(rigid)) { body.drop(); return err~; }
	}

	self.bodies.push(body);
}

<*
 Take a node's body away. False when it had none, so removing twice is not an
 error — the same answer `PhysicsWorld.remove_body` gives for the same reason.
*>
fn bool Physics.remove(&self, NodeId node)
{
	if (!self.opened) return false;

	foreach (i, &body : self.bodies)
	{
		if (!(body.node == node)) continue;

		self.world.remove_body(body.id);
		// **Drained here rather than at the next step.** `run_step` clears the
		// world's event lists at the top, so the EXIT and END events
		// `remove_body` just emitted — for a body destroyed inside a trigger,
		// which is the case that matters — would be gone before anything read
		// them.
		self.harvest();

		body.drop();
		self.bodies.remove_at(i);
		return true;
	}
	return false;
}

<*
 Move the world's events somewhere `run_step` will not clear them from.
*>
fn void Physics.harvest(&self)
{
	foreach (event : self.world.trigger_events)
	{
		self.trigger_events.push({
			.trigger = self.node_of(event.trigger_id),
			.other = self.node_of(event.other_id),
			.entered = event.type == collision::TriggerEventType.ENTER,
		});
	}
	foreach (event : self.world.contact_events)
	{
		self.contact_events.push({
			.a = self.node_of(event.body_a),
			.b = self.node_of(event.body_b),
			.started = event.type == collision::ContactEventType.START,
			.normal = event.normal,
			.point = event.contact_point,
		});
	}
	self.world.trigger_events.clear();
	self.world.contact_events.clear();
}

<*
 Forget what nobody is going to be told.

 Called on the frames that dispatch nothing — no animation loop means no
 handlers run, exactly as it does for keys and clicks — so a world stepping
 under a scene with no callback cannot grow a list forever.
*>
fn void Physics.drop_events(&self)
{
	self.trigger_events.clear();
	self.contact_events.clear();
}

<*
 The node a body id belongs to, or NO_NODE. What event dispatch needs: the
 solver speaks in body ids and a script has only ever seen objects.
*>
fn NodeId Physics.node_of(&self, sz id)
{
	foreach (&body : self.bodies)
	{
		if (body.id == id) return body.node;
	}
	return NO_NODE;
}

<*
 Set the world's gravity. Y-up, in world units per second squared.
*>
fn void Physics.set_gravity(&self, Vec3 gravity)
{
	self.open();
	self.world.gravity = gravity;
}

<*
 Push whatever a script wrote onto the kinematic bodies, before the step.

 `set_kinematic_target` derives a velocity from the delta, which is what lets a
 dynamic body bounce off a moving platform correctly instead of being teleported
 through by it.
*>
fn void Physics.drive_kinematic(&self, Scene* scene)
{
	foreach (&body : self.bodies)
	{
		if (body.kind != BodyKind.KINEMATIC) continue;
		Node* node = scene.node(body.node);
		if (node == null) continue;
		self.world.set_kinematic_target(
			body.id, node.position, node.rotation, (float)(PHYSICS_STEP_MS / 1000.0)
		);
	}
}

<*
 Copy the solver's answer back onto the nodes it owns.

 Dynamic only. A static body never moved, and a kinematic one is already where
 the script put it — writing back over that would undo the very thing kinematic
 means.
*>
fn void Physics.write_back(&self, Scene* scene)
{
	foreach (&body : self.bodies)
	{
		if (body.kind != BodyKind.DYNAMIC) continue;

		collision::Rigidbody*? rigid = self.world.find_body(body.id);
		if (catch rigid) continue;

		Node* node = scene.node(body.node);
		if (node == null) continue;

		node.position = rigid.collider.translation;
		node.rotation = rigid.collider.rotation;
		node.dirty = true;
	}
}

<*
 Take out any body the solver has lost control of.

 **A scene an agent built will contain interpenetrating geometry**, because
 describing a scene in a script is exactly how a box ends up spawned inside a
 wall. XPBD answers a deep overlap with a correspondingly deep correction, and
 a few substeps of that produces a transform with no finite value in it. The
 next `spatial_map.update` then trips a `@require` and takes the process with
 it — which is the worst possible outcome for an API whose whole point is that
 an agent can try something, look at the picture and correct it.

 So the check is here, before the step, and a body that has gone non-finite or
 implausibly far is removed and reported rather than stepped again. It cannot
 catch a divergence that begins and completes inside one step; it catches the
 case that matters, which is the frame *after* a body first goes wrong.

 @return `how many bodies were evicted.`
*>
fn sz Physics.evict_diverged(&self)
{
	sz before = self.diverged.len();

	// Backwards: `remove` erases from the same list this walks.
	for (sz i = self.bodies.len(); i > 0; i--)
	{
		PhysicsBody* body = &self.bodies[i - 1];
		if (body.kind != BodyKind.DYNAMIC) continue;

		collision::Rigidbody*? rigid = self.world.find_body(body.id);
		if (catch rigid) continue;

		Vec3 at = rigid.collider.translation;
		bool finite = math::is_finite(at.x) && math::is_finite(at.y) && math::is_finite(at.z)
			&& math::is_finite(rigid.collider.rotation.i)
			&& math::is_finite(rigid.collider.rotation.j)
			&& math::is_finite(rigid.collider.rotation.k)
			&& math::is_finite(rigid.collider.rotation.l);

		// The bound is generous on purpose: a body that has fallen off the
		// world is a game's business and not a failure, so only something that
		// has plainly left the simulation is taken.
		bool in_range = finite && at.x * at.x + at.y * at.y + at.z * at.z < DIVERGED_DISTANCE_SQ;

		if (!in_range)
		{
			self.diverged.push(body.node);
			self.remove(body.node);
		}
	}

	return self.diverged.len() - before;
}

<*
 One frame's worth of physics — `game.md` G5/S1.

 The accumulator is the whole of it: whatever the frame took, the world advances
 in fixed 60 Hz steps and keeps the remainder. `PHYSICS_MAX_STEPS` is where a
 frame that ran very long stops trying to catch up, and dropping the rest is
 deliberate — carrying it is how one slow frame becomes a spiral that never
 recovers.
*>
fn void Physics.step(&self, Scene* scene, double elapsed_ms)
{
	if (!self.opened || self.bodies.len() == 0) return;

	self.evict_diverged();
	if (self.bodies.len() == 0) return;

	self.drive_kinematic(scene);

	self.accumulator_ms += elapsed_ms;

	
	int steps = 0;
	while (self.accumulator_ms >= PHYSICS_STEP_MS && steps < PHYSICS_MAX_STEPS)
	{
		self.world.run_step((float)(PHYSICS_STEP_MS / 1000.0), 1, 4);
		self.accumulator_ms -= PHYSICS_STEP_MS;
		steps++;
	}

	if (self.accumulator_ms > PHYSICS_STEP_MS) self.accumulator_ms = 0;

	if (steps > 0)
	{
		self.harvest();
		self.write_back(scene);
	}
}
