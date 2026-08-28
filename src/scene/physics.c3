
module three;

import std::collections::list;
import std::collections::map;
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
	NODE_IS_NOT_TOP_LEVEL,
	// A heightfield collider was asked for on a node whose mesh is not terrain.
	// There is no grid to take, and approximating one would be a collider that
	// looks right and behaves wrongly.
	NODE_IS_NOT_TERRAIN,
	// A joint was asked for on a node that has no body to hold.
	JOINT_NEEDS_A_BODY,
	// Both ends of a joint are the same object.
	JOINT_ON_ONE_BODY,
	// A trigger is never integrated, so a joint could not move it.
	JOINT_ON_A_TRIGGER,
	// Neither end of the joint can move, so the constraint has nothing to solve.
	JOINT_NEEDS_A_MOVER,
	// A joint with an empty limit list holds nothing.
	JOINT_HAS_NO_LIMITS,
	// More than three limits on one side. There are only three axes.
	JOINT_HAS_TOO_MANY_LIMITS,
	// A soft body was asked for on a mesh whose points never reached the host.
	SOFT_HAS_NO_POINTS,
	// A soft body was asked for on a skinned mesh. Two things would own the same
	// vertices — see `Physics.add_soft`.
	SOFT_IS_SKINNED;

// What a script is told when it writes a transform the solver owns. One string
// rather than two copies, because it is raised from both transform doors and a
// sentence that drifts between them is worse than no sentence.
const String PHYSICS_OWNS_TRANSFORM =
	"this object's transform belongs to the physics solver — a dynamic body is "
	"moved by the world, not by a script. Make the body kinematic to drive it "
	"yourself, or three.physics.remove(object) first.";

// The same refusal for a soft body, which needs its own sentence because the
// escape is a different call and the reason is a different one: the node sits at
// the particles' average and the vertices are written relative to it, so moving
// the node moves the drawing out from under the simulation.
const String PHYSICS_OWNS_SOFT_TRANSFORM =
	"this object's transform belongs to the soft body solver — its position is "
	"where the particles average out to, rewritten every step. Push it with "
	"three.physics.pin(object, i, [x, y, z]), or three.physics.removeSoft(object) "
	"first.";

// The fixed tick. Not a setting: two worlds stepped at different rates are two
// different simulations, and the determinism `PhysicsWorld.state_hash` offers is
// worth more than a knob.
const double PHYSICS_STEP_MS = 1000.0 / 60.0;

// The most steps one frame may run to catch up. Past this the backlog is dropped
// rather than run, which is the difference between a stutter and a spiral: every
// frame that ran long would otherwise ask the next one to run longer still.
const int PHYSICS_MAX_STEPS = 5;

// How far a body may get from the origin before it is treated as lost rather than
// merely falling. Ten kilometres of world units: past anything a scene means, and
// well short of where float precision stops describing a position.
const float DIVERGED_DISTANCE_SQ = 10_000.0f * 10_000.0f;

// Y-up. The only place a gravity direction is chosen.
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
	<*
	 The terrain itself — the grid of heights a `TerrainGeometry` was built from,
	 handed to the solver as one shape.

	 Only for a node whose mesh is a terrain, because that is the only mesh with a
	 grid; anything else is refused by name at `build_collider` rather than
	 approximated into something that would look right and behave wrongly.

	 The alternative is a chain of invisible box colliders — 81 of them for one
	 corridor, and a path that has to be dead flat at y = 0 for its whole length,
	 because a flat floor is the only shape a chain of axis-aligned boxes can be.
	*>
	HEIGHTFIELD,
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
	// The address is the point. `TransformedShape.shape` is an interface value
	// pointing straight at this allocation, so a `List` of shapes that reallocated
	// on its next push would leave every body already in the world pointing into
	// freed memory. One allocation per body, released in `drop`.
	void* collider; //CollisionShape
}

<*
 Gives back the one allocation a body owns.

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
	if (self.shape == ColliderShape.HEIGHTFIELD)
	{
		collision::Heightmap* field = (collision::Heightmap*)self.collider;
		field.free();
	}
	mem::free(self.collider);
	self.collider = null;
}

<*
 A trigger overlap starting or ending, in the terms a script thinks in.

 Nodes rather than body ids, resolved here rather than at dispatch. The point of
 `remove_body` emitting EXIT is that a body destroyed inside a trigger is still
 seen to leave it — and by the time the handler runs, that body is gone from
 `bodies` and its id resolves to nothing. Whatever a script is told has to be
 captured while the body still exists.
*>
struct TriggerHit
{
	NodeId trigger;
	NodeId other;
	bool entered;
}

<*
 Two bodies touching or coming apart. `normal` and `point` mean something only on
 a start, which is the library's rule and is repeated in the doc the prelude
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
	// Held here rather than read straight off the world because `run_step` clears
	// the world's own lists at the top: a body removed between frames would
	// otherwise have its EXIT events wiped before anything saw them.
	List{TriggerHit} trigger_events;
	List{ContactHit} contact_events;

	// Bodies the solver lost control of, taken out of the world and waiting to be
	// reported. See `Physics.evict_diverged`.
	List{NodeId} diverged;

	// The joints a script has asked for, in the order it asked. Kept here as well
	// as in the world because the world's own list is not addressable: it has no
	// remove, and `remove_body` prunes it from under us. See
	// `Physics.rebuild_joints`.
	List{PhysicsJoint} joints;
	// The soft bodies, and the mesh each one deforms — `Physics.add_soft`.
	List{SoftMesh} softs;

	bool opened;
}

fn void Physics.open(&self)
{
	if (self.opened) return;
	self.world = collision::DEFAULT_PHYSICS_WORLD;
	// On the heap, explicitly. A zero-valued C3 map or list initializes itself
	// into the *temp* allocator on first use, and a world that outlives a frame
	// cannot have its storage in a pool released at the end of one. The crash
	// lands inside a hash table, several frames from anything that mentions
	// physics.
	self.world.init(mem);
	self.world.gravity = PHYSICS_GRAVITY;

	// And this side's lists too, for the same reason. A bare C3 list binds itself
	// to the temp allocator on its first push, so `bodies` would live in whichever
	// frame's pool happened to be open when the first body was added. What that
	// looks like: `len()` keeps answering, because the count is in the struct and
	// only the buffer is gone, so the world goes on stepping while every body
	// reads as garbage and nothing is written back — physics that runs but does
	// not move anything.
	self.bodies.init(mem);
	self.trigger_events.init(mem);
	self.contact_events.init(mem);
	self.diverged.init(mem);
	self.joints.init(mem);
	self.softs.init(mem);
	// Single-threaded, deliberately. Handlers, scene and device are all touched
	// from one thread, so nothing needs a lock. The solver's pool is confined to
	// the inside of `run_step` and joined before it returns, but a body count that
	// fits in a scene an agent builds is not where a thread pool pays for itself.
	self.world.thread_count = 1;
	self.next_id = 1;
	self.opened = true;
}

fn void Physics.close(&self)
{
	if (!self.opened) return;
	foreach (&body : self.bodies) body.drop();
	self.bodies.free();
	foreach (&soft : self.softs) soft.drop();
	self.softs.free();
	self.joints.free();
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
 bodies pays nothing, which is the common case for the transform-write check in
 `bind_scene.c3` that asks this on every write a script makes.
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
 The solver's body for a node, or null.

 `Physics.body_for` answers with this side's record — the node, the collider, the
 kind. This answers with the *solver's*, which is where the velocity lives and
 where an impulse has to land. Two lookups rather than one field because the
 solver owns its own storage and hands out a pointer a later `add_body` could
 move; taking it fresh at each call is what makes that safe.
*>
fn collision::Rigidbody* Physics.rigidbody_for(&self, NodeId node)
{
	PhysicsBody* body = self.body_for(node);
	if (body == null) return null;
	if (self.world.bodies.len() == 0) return null;

	collision::Rigidbody*? rigid = self.world.find_body(body.id);
	if (catch rigid) return null;
	return rigid;
}

<*
 Whether a script may set this node's velocity or push it with an impulse.

 Dynamic only, and the two refusals are different mistakes. A static body has an
 inverse mass of zero, so an impulse is arithmetically a no-op and a velocity
 written onto it is overwritten by the next integration — the script sees nothing
 happen and has nothing to read. A kinematic body has its transform driven from
 the script every step by `set_kinematic_target`, so a velocity written here is
 discarded a fraction of a step later, which is worse because it *sometimes*
 appears to work.

 Both are refused by name at the binding rather than silently absorbed here — the
 same call `Scene.set_position` makes for a dynamic body's transform, pointing
 the other way: each kind of body has exactly one way to be moved, and the other
 one throws.
*>
fn bool Physics.can_be_pushed(&self, NodeId node)
{
	PhysicsBody* body = self.body_for(node);
	return body != null && body.kind == BodyKind.DYNAMIC;
}

<*
 Wakes a body that an impulse or a velocity is about to reach.

 A body at rest for half a second is asleep, and a sleeping body is skipped by
 integration entirely, so an impulse applied to one changes a number nothing will
 ever read. Without this the same line of script works on a rolling crate and
 does nothing to a settled one, which reads as the verb being unreliable rather
 than as sleep. The *island* rather than the body alone, because whatever this
 one is resting on has to start being integrated too, or the push drives it into
 a neighbour that is not moving yet.

 Not an optimisation: removing these two lines turns
 `an_impulse_wakes_a_settled_body_and_moves_it` red — a settled ball given a
 six-unit impulse travels -0.003 units, because the push landed in a velocity the
 integrator never reads. That is exactly the state a binding which only wrote
 `linear_velocity` would leave behind on its first call, which is why this cannot
 be moved to the prelude.
*>
fn void Physics.wake(&self, collision::Rigidbody* rigid)
{
	self.world.wake_island(rigid);
	rigid.stop_sleeping();
}

<*
 Whether a script may write this node's transform.

 False only for a body the solver drives. A static body never moves and a
 kinematic one is *supposed* to be moved — through `set_kinematic_target`, which
 `Physics.drive` calls with whatever the script wrote.
*>
fn bool Physics.owns_transform(&self, NodeId node)
{
	if (self.soft_for(node) != null) return true;
	PhysicsBody* body = self.body_for(node);
	if (body == null) return false;
	return body.kind == BodyKind.DYNAMIC;
}

<*
 Which sentence a refused transform write gets.

 Two, because the escape is a different call for each: a rigid body is removed or
 made kinematic, a soft body is pushed with a pin.
*>
fn String Physics.transform_refusal(&self, NodeId node)
{
	return self.soft_for(node) != null ? PHYSICS_OWNS_SOFT_TRANSFORM : PHYSICS_OWNS_TRANSFORM;
}

<*
 Builds the collider a body will carry, from the mesh the node draws.

 The collider comes from the asset. A box and a sphere are the mesh's own bounds,
 which every mesh slot carries from the moment its glTF was parsed; a hull is
 `collision::quickhull` over the positions the picking tree already keeps, which
 is exactly what `ConvexGeometry` does — so a convex rock's collider is its own
 geometry, computed by the same function, and is exact rather than an
 approximation of itself.

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
			// `hull_positions` is the picking tree's, and it exists from the mesh's
			// upload — which `scene.add()` triggers, so a node in the scene has one.
			// A mesh that never reached the device has not, and a box of the right
			// size beats a hull of nothing.
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

		case HEIGHTFIELD:
			// The grid the geometry was built from, not a reconstruction of it. A
			// terrain asset keeps its `Heightfield`, so the collider is the same
			// numbers the vertices came out of — which makes
			// `terrain.heightAt(x, z)` and the ground a body rests on the same
			// surface by construction rather than by two derivations agreeing.
			Heightfield* field = assets.terrain_field(node.asset);
			if (field == null) return NODE_IS_NOT_TERRAIN~;
			return build_heightmap(field);
	}
}

<*
 A `collision::Heightmap` from a terrain's own grid.

 The one thing that is not a straight copy is the cell size. A
 `collision::Heightmap` has one, and a `Heightfield` has two — `width / segments`
 and `depth / segments` — which are the same number only for a square terrain.
 Rather than refuse a rectangular one, or grow the library's shape a second cell
 size nothing else would set, the heights are resampled onto a square grid at the
 finer of the two spacings.

 For a square terrain that resampling is exact and free: the sample points land
 on the original grid points, and `height_at` at a grid point returns that
 sample. The rectangular case pays, and it pays in memory rather than in accuracy.

 @return `A heap Heightmap the body owns, freed by PhysicsBody.drop.`
*>
fn collision::Heightmap* build_heightmap(Heightfield* field)
{
	float cell = math::min(field.cell_x(), field.cell_z());
	if (cell <= 0.0f) cell = 1.0f;

	uint nx = (uint)math::ceil(field.width / cell) + 1;
	uint nz = (uint)math::ceil(field.depth / cell) + 1;

	// On the heap, explicitly. A zero-valued C3 list binds itself to the *temp*
	// allocator on its first push, and this one is owned by a body and outlives
	// every pool there is. The failure is not a crash: the pool is released, the
	// heights become whatever is there now, and bodies start falling through
	// terrain or being flung out of the world by a correction computed from
	// garbage.
	collision::Heights heights;
	heights.init(mem, (usz)nx * (usz)nz);

	float low_x = -field.width * 0.5f;
	float low_z = -field.depth * 0.5f;

	// Row-major in z then x, which is the order `Heightmap.get_height_at_grid`
	// reads and the same order `Heightfield.heights` is already in.
	for (uint j = 0; j < nz; j++)
	{
		float z = low_z + (float)j * cell;
		for (uint i = 0; i < nx; i++)
		{
			heights.push(field.height_at(low_x + (float)i * cell, z));
		}
	}

	collision::Heightmap* heap = mem::new(collision::Heightmap);
	*heap = collision::create_heightmap_from_list(heights, nx, nz, cell, { low_x, 0, low_z });
	return heap;
}

<*
 Hands the collider to the world as the interface value it wants.

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
		case HEIGHTFIELD: shape.shape = (collision::Heightmap*)body.collider;
	}

	return shape;
}

<*
 Gives a node a body.

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

	// World space, so the parent has to be what world space is measured from. The
	// alternative is writing a world transform into a nested node's local slot
	// every frame and calling the result physics.
	if (!(node.parent == scene.root)) return NODE_IS_NOT_TOP_LEVEL~;

	self.remove(node_id);
	// One or the other. A soft body writes the vertices this node draws and a
	// rigid one writes its transform, so a node holding both would be simulated
	// twice and drawn once.
	self.remove_soft(node_id);

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
 Takes a node's body away. False when it had none, so removing twice is not an
 error — the same answer `PhysicsWorld.remove_body` gives for the same reason.
*>
fn bool Physics.remove(&self, NodeId node)
{
	if (!self.opened) return false;

	foreach (i, &body : self.bodies)
	{
		if (!(body.node == node)) continue;

		self.world.remove_body(body.id);
		// Drained here rather than at the next step. `run_step` clears the world's
		// event lists at the top, so the EXIT and END events `remove_body` just
		// emitted — for a body destroyed inside a trigger, which is the case that
		// matters — would be gone before anything read them.
		self.harvest();

		body.drop();
		self.bodies.remove_at(i);
		// After the world has pruned its own copies, and before anything rebuilds
		// from ours — `drop_joints_on` says what goes wrong the other way round.
		self.drop_joints_on(node);
		return true;
	}
	return false;
}

<*
 Moves the world's events somewhere `run_step` will not clear them from.
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
 Forgets what nobody is going to be told.

 Called on the frames that dispatch nothing — no animation loop means no handlers
 run, exactly as for keys and clicks — so a world stepping under a scene with no
 callback cannot grow a list forever.
*>
fn void Physics.drop_events(&self)
{
	self.trigger_events.clear();
	self.contact_events.clear();
}

<*
 The node a body id belongs to, or NO_NODE. What event dispatch needs: the solver
 speaks in body ids and a script has only ever seen objects.
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
 Sets the world's gravity. Y-up, in world units per second squared.
*>
fn void Physics.set_gravity(&self, Vec3 gravity)
{
	self.open();
	self.world.gravity = gravity;

	// The wake is the half that is easy to leave out. A settled scene has put its
	// bodies to sleep, and a sleeping body is skipped by the integrator — so
	// gravity changes and nothing falls, which reads as the setting having been
	// ignored. The library has no gravity setter to hide this in, so everything
	// that is not static gets woken: the new pull is a different pull on all of it.
	collision::RigidBodyIterator iter = self.world.bodies.value_iter();
	while (iter.next())
	{
		collision::Rigidbody*? body = iter.get();
		if (catch body) continue;
		if (body.is_static) continue;
		body.stop_sleeping();
	}
}

<*
 Whether the solver still has something to move.

 THE FRAME LOOP SLEEPS. `main.c3` parks in `getEvent(wait: true)` whenever the
 last frame is still on screen and nothing is known to want another one, which is
 what keeps an idle window off the CPU. Every term of that condition is something
 that would be lost by sleeping through it, and a falling body is one of them: a
 scene with bodies and no `setAnimationLoop` is not "animating" by any test the
 runtime had, so the world advanced only while the mouse was moving and stood
 still the moment it stopped.

 Awake, not merely present. A settled scene is supposed to let the window sleep —
 that is the whole point of the solver's own sleeping — so this asks whether any
 body is still being integrated rather than whether any body exists. Kinematic
 bodies are not counted: they move because a script writes their transform, and a
 script that runs is already a reason to stay awake.

 @return `true while any dynamic rigid body or any soft body is awake.`
*>
fn bool Physics.is_moving(&self)
{
	if (!self.opened) return false;

	collision::RigidBodyIterator iter = self.world.bodies.value_iter();
	while (iter.next())
	{
		collision::Rigidbody*? body = iter.get();
		if (catch body) continue;
		if (body.is_active()) return true;
	}

	foreach (&sb : self.world.soft_bodies)
	{
		if (!sb.sleeping) return true;
	}
	return false;
}

<*
 Pushes whatever a script wrote onto the kinematic bodies, before the step.

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
 Copies the solver's answer back onto the nodes it owns.

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
		// Not `node.dirty = true`: the flag alone is not enough now that the
		// world-matrix walk may skip itself. See `Scene.mark_moved`.
		scene.mark_moved(body.node);
	}
}

<*
 Takes out any body the solver has lost control of.

 A scene an agent built will contain interpenetrating geometry, because
 describing a scene in a script is exactly how a box ends up spawned inside a
 wall. XPBD answers a deep overlap with a correspondingly deep correction, and a
 few substeps of that produces a transform with no finite value in it. The next
 `spatial_map.update` then trips a `@require` and takes the process with it —
 the worst possible outcome for an API whose point is that an agent can try
 something, look at the picture and correct it.

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

		// The bound is generous on purpose: a body that has fallen off the world is
		// a game's business and not a failure, so only something that has plainly
		// left the simulation is taken.
		bool in_range = finite && at.x * at.x + at.y * at.y + at.z * at.z < DIVERGED_DISTANCE_SQ;

		if (!in_range)
		{
			self.diverged.push(body.node);
			self.remove(body.node);
		}
	}

	// The same check for the soft bodies, off the box the solver leaves on each
	// one at the end of `xpbd_solve` rather than off the particles: a soft body
	// that has gone non-finite has gone non-finite everywhere, and this is a
	// constant-time read where walking the particles is not.
	for (sz i = self.softs.len(); i > 0; i--)
	{
		SoftMesh* record = &self.softs[i - 1];
		collision::SoftBody*? body = self.world.find_softbody(record.id);
		if (catch body) continue;
		if (finite_and_near(body.aabb.min) && finite_and_near(body.aabb.max)) continue;

		self.diverged.push(record.node);
		self.remove_soft(record.node);
	}

	return self.diverged.len() - before;
}

<*
 Whether a point is a number and still somewhere a scene means — `Physics.evict_diverged`'s
 test, as one expression.
*>
fn bool finite_and_near(Vec3 at) @local
{
	if (!math::is_finite(at.x) || !math::is_finite(at.y) || !math::is_finite(at.z)) return false;
	return at.length_sq() < DIVERGED_DISTANCE_SQ;
}

<*
 One frame's worth of physics.

 The accumulator is the whole of it: whatever the frame took, the world advances
 in fixed 60 Hz steps and keeps the remainder. `PHYSICS_MAX_STEPS` is where a
 frame that ran very long stops trying to catch up, and dropping the rest is
 deliberate — carrying it is how one slow frame becomes a spiral that never
 recovers.
*>
fn void Physics.step(&self, Scene* scene, double elapsed_ms)
{
	if (!self.opened || (self.bodies.len() == 0 && self.softs.len() == 0)) return;

	self.evict_diverged();
	if (self.bodies.len() == 0 && self.softs.len() == 0) return;

	self.drive_kinematic(scene);

	self.accumulator_ms += elapsed_ms;

	
	int steps = 0;
	// `run_step` requires a rigid body — its broad phase, its islands and its
	// event lists are all about them — and a scene may hold nothing but soft
	// bodies. `solve_soft_bodies` is the phase `run_step` would have reached, with
	// the same argument, so a soft-only world steps identically rather than
	// needing an invisible box in it to be legal.
	bool rigid = self.bodies.len() > 0;
	while (self.accumulator_ms >= PHYSICS_STEP_MS && steps < PHYSICS_MAX_STEPS)
	{
		float dt = (float)(PHYSICS_STEP_MS / 1000.0);
		if (rigid)
		{
			self.world.run_step(dt, 1, 4);
		}
		else
		{
			self.world.solve_soft_bodies(dt);
		}
		self.accumulator_ms -= PHYSICS_STEP_MS;
		steps++;
	}

	if (self.accumulator_ms > PHYSICS_STEP_MS) self.accumulator_ms = 0;

	if (steps > 0)
	{
		self.harvest();
		self.write_back(scene);
		self.write_back_soft(scene);
	}
}

<*
 Puts every soft body's node where its particles ended up, and refreshes the
 normals and bounds the renderer reads.

 The counterpart of `write_back` for the bodies that have no transform of their
 own: what moves is the vertices, and the node follows them rather than the other
 way round.
*>
fn void Physics.write_back_soft(&self, Scene* scene)
{
	foreach (&record : self.softs) self.settle_soft(scene, record);
}

// ---------------------------------------------------------------------------
// Joints
//
// **The limit list is the joint**, and it is glTF's list rather than a shape of
// this project's own. `KHR_physics_rigid_bodies` describes a constraint as a set
// of limits, each naming some of the joint frame's axes and the range those axes
// are held to — and `collision::GenericJoint3D` is two lists of exactly that, so
// a limit read out of a file and a limit written by a script are the same thing.
// A hinge is not a kind here; it is three linear axes held, two angular axes held
// and one left alone. `prelude/physics.js` keeps the four familiar words and
// expands each into its limits before it calls, which is why nothing below knows
// what a hinge is.
//
// **No range is a lock.** A limit with `min == max == 0` holds its axes at zero,
// which is glTF's default for both fields and the library's reading of them
// (`solver/joint.c3`). It is the opposite of what "no limit" sounds like, and it
// is the reason the prelude refuses `range: [0, 0]` on the shorthand — there,
// somebody asking for a range and getting a weld is a mistake rather than a
// statement.

<*
 One entry of a joint's limit list — glTF's `limits[i]`, flattened.

 The axes are a mask over the joint's own frame: bit 1 is axis 0, bit 2 is axis 1,
 bit 4 is axis 2. Axis 0 is `JointSpec.axis` and the other two are derived from it,
 so "free about axis 0" is a hinge about whatever direction the script named.

 **A mask of more than one axis becomes one limit per axis**, which is where this
 and the file format part company. glTF reads a multi-axis limit as a bound on the
 *length* of the error across those axes — two angular axes are a cone — and the
 solver reads `Limit.axes` as a single direction to project onto, which for a
 mask of two would be their diagonal and is nobody's intent. Split per axis the
 two readings agree exactly for a lock, and differ for a range: a box rather than
 a cone. Locks are what masks are nearly always for.
*>
struct JointLimit
{
	bool angular;
	char axes;
	float min;
	float max;
	// This limit's own, or zero to take the joint's — see `JointSpec.stiffness`
	// for which end of the scale zero is, and for what `damping` does not do.
	float stiffness;
	float damping;
}

<*
 What a script asked for, before it becomes a `GenericJoint3D`.

 Flattened out of the options object in `prelude/physics.js`, which is where the
 defaults, the four shorthand words and the sentences a bad one gets live.
*>
struct JointSpec
{
	// Where the two bodies are pinned together, in world space. Without one the
	// pivot is the midpoint of the two body centres, which is where two things
	// standing next to each other meet.
	bool has_pivot;
	Vec3 pivot;
	// Axis 0 of the joint's frame, in world space at the moment the joint is made.
	// Axes 1 and 2 are perpendicular to it — see `basis_about`.
	Vec3 axis;
	<*
	 The spring constant for a limit that names none of its own.

	 **Zero is the rigid end, not the soft one.** `solver/joint.c3` reads it as
	 `(1 / stiffness) / dt²` and special-cases zero to no compliance at all, so
	 bigger is stiffer, zero is a wall, and a small positive number is the
	 softest thing there is. Enough to be felt on a one-kilogram prop at 60 Hz is
	 in the low thousands.
	*>
	float stiffness;
	<*
	 Carried into the joint and **not read by the solver**.

	 It is here because glTF's limits have one and a limit read out of a file
	 should survive being passed straight in — not because it does anything yet.
	 `collision::Limit.damping` and `GenericJoint3D.dampening` are both declared
	 and both unread; the day one of them is, this is already wired to it.
	*>
	float damping;
	// Whether the two bodies still collide with each other. Off by default,
	// because two things bolted together usually overlap where they are bolted.
	bool collide;
	// The limits, in the order the script gave them. Borrowed for the length of
	// the call — `add_joint` copies what it needs into the joint.
	JointLimit[] limits;
}

<*
 One joint, and the two nodes it names.

 The whole `GenericJoint3D` is kept rather than an index into the world's list,
 because that list is rebuilt from this one — see `Physics.rebuild_joints`.
*>
struct PhysicsJoint
{
	sz id;
	NodeId a;
	NodeId b;
	collision::GenericJoint3D joint;
}

<*
 Two unit vectors perpendicular to `axis` and to each other.

 The seed is whichever cardinal axis `axis` is least parallel to, so the cross
 product never collapses.
*>
fn void basis_about(Vec3 axis, Vec3* side, Vec3* up) @local
{
	Vec3 seed = { 1, 0, 0 };
	if (math::abs(axis.x) > 0.9f) seed = { 0, 1, 0 };
	*side = axis.cross(seed).normalize();
	*up = axis.cross(*side);
}

<*
 Adds one limit, or says the list is full.

 `collision::Limits` is a `FixedList` of three and pushing a fourth trips a
 contract. Three is exactly the number of axes there are, so a fourth is a script
 naming one twice — which is a sentence to be told rather than a process to take
 down.
*>
fn bool push_limit(collision::Limits* limits, Vec3 axes, JointLimit limit) @local
{
	if (limits.len() >= 3) return false;
	limits.push({
		.axes = axes,
		.min = limit.min,
		.max = limit.max,
		.stiffness = limit.stiffness,
		.damping = limit.damping,
	});
	return true;
}

<*
 Joins two body-backed nodes, held by the limits the spec carries.

 The joint is made *where the bodies are now*: the anchors are the pivot seen
 from each body, and `relative_orientation` is whatever the two are turned to
 relative to each other at this moment. So a script places both objects and then
 joins them, rather than describing the rest pose in numbers.

 @return `The joint's id, for three.physics.removeJoint.`
*>
fn sz? Physics.add_joint(&self, NodeId a, NodeId b, JointSpec spec)
{
	if (!self.opened) return JOINT_NEEDS_A_BODY~;
	if (a == b) return JOINT_ON_ONE_BODY~;
	if (spec.limits.len == 0) return JOINT_HAS_NO_LIMITS~;

	PhysicsBody* record_a = self.body_for(a);
	PhysicsBody* record_b = self.body_for(b);
	if (record_a == null || record_b == null) return JOINT_NEEDS_A_BODY~;
	if (record_a.kind == BodyKind.TRIGGER || record_b.kind == BodyKind.TRIGGER) return JOINT_ON_A_TRIGGER~;
	// One end has to be integrated. Two static bodies have zero inverse mass
	// between them, which the solver answers by returning early — a joint that
	// exists, costs a constraint every substep and does nothing.
	if (record_a.kind != BodyKind.DYNAMIC && record_b.kind != BodyKind.DYNAMIC) return JOINT_NEEDS_A_MOVER~;

	collision::Rigidbody* rigid_a = self.rigidbody_for(a);
	collision::Rigidbody* rigid_b = self.rigidbody_for(b);
	if (rigid_a == null || rigid_b == null) return JOINT_NEEDS_A_BODY~;

	Vec3 at_a = rigid_a.collider.translation;
	Vec3 at_b = rigid_b.collider.translation;
	Vec3 pivot = spec.has_pivot ? spec.pivot : (at_a + at_b) * 0.5f;

	collision::GenericJoint3D joint = {
		.body_a = record_a.id,
		.body_b = record_b.id,
		.collides = spec.collide,
		.anchor_a = rigid_a.collider.rotation.conjugate() * (pivot - at_a),
		.anchor_b = rigid_b.collider.rotation.conjugate() * (pivot - at_b),
		.relative_orientation = rigid_a.collider.rotation.conjugate() * rigid_b.collider.rotation,
		.stifness = spec.stiffness,
		.dampening = spec.damping,
	};

	// The joint's own frame, in world space. Axis 0 is what the script named and
	// the other two are derived from it, so a limit that says "axis 1 and 2" means
	// the plane the axle is normal to whichever way the axle points.
	Vec3[3] frame;
	frame[0] = spec.axis.length_sq() > 0 ? spec.axis.normalize() : (Vec3) { 0, 1, 0 };
	basis_about(frame[0], &frame[1], &frame[2]);

	// Into body B's frame, which is where an angular limit's axis is read from —
	// `solver/joint.c3` resolves it through `relative_orientation` and reads a
	// linear one as a world direction with no resolution at all. The asymmetry is
	// the library's and it shows: a slider's rail does not turn with the bodies.
	Quaternionf into_b = rigid_b.collider.rotation.conjugate();

	foreach (limit : spec.limits)
	{
		for (int i = 0; i < 3; i++)
		{
			if ((limit.axes & (char)(1 << i)) == 0) continue;

			JointLimit one = limit;
			// The joint's own spring for a limit that named none. One number in
			// one place, rather than every limit in a shorthand's expansion
			// carrying a copy of it.
			if (one.stiffness == 0) one.stiffness = spec.stiffness;
			if (one.damping == 0) one.damping = spec.damping;

			bool room = limit.angular
				? push_limit(&joint.angular_limits, into_b * frame[i], one)
				: push_limit(&joint.linear_limits, frame[i], one);
			if (!room) return JOINT_HAS_TOO_MANY_LIMITS~;
		}
	}

	self.world.add_constraint(joint)!;

	// Both ends, for the reason an impulse wakes one: a sleeping body is skipped
	// by integration, so a joint made onto a settled crate would hold nothing
	// until something else happened to it.
	self.wake(rigid_a);
	self.wake(rigid_b);

	sz id = self.next_id++;
	self.joints.push({ .id = id, .a = a, .b = b, .joint = joint });
	return id;
}

<*
 Writes `self.joints` back over the world's list.

 The world has `add_constraint` and no remove, and `remove_body` prunes its list
 from underneath us — so there is no index into it that stays meaning the same
 joint. Rebuilding from the record this side keeps is the only arrangement where
 removing the second of three joints cannot silently remove the third.

 The collision filter goes with it, and that is safe because `add_constraint` is
 the only thing that ever writes one: a filter entry and a non-colliding joint
 are the same fact.
*>
fn void Physics.rebuild_joints(&self)
{
	self.world.joints.clear();
	self.world.filters.clear();
	foreach (&record : self.joints)
	{
		if (catch self.world.add_constraint(record.joint)) continue;
	}
	self.world.islands_dirty = true;
}

<*
 Takes one joint away. False when the id names nothing, so removing twice is not
 an error.
*>
fn bool Physics.remove_joint(&self, sz id)
{
	if (!self.opened) return false;
	foreach (i, &record : self.joints)
	{
		if (record.id != id) continue;
		self.joints.remove_at(i);
		self.rebuild_joints();
		return true;
	}
	return false;
}

<*
 Forgets every joint that named this node.

 Called from `Physics.remove`, and the ordering there is the point: the world has
 already pruned its own copies, and a rebuild that did not drop these first would
 put them back — pointing at a body id that no longer resolves, which
 `GenericJoint3D.create_xpbd_constraint` answers by taking the process down.
*>
fn void Physics.drop_joints_on(&self, NodeId node)
{
	bool dropped = false;
	for (sz i = self.joints.len(); i > 0; i--)
	{
		PhysicsJoint* record = &self.joints[i - 1];
		if (!(record.a == node) && !(record.b == node)) continue;
		self.joints.remove_at(i - 1);
		dropped = true;
	}
	if (dropped) self.rebuild_joints();
}

// ---------------------------------------------------------------------------
// Soft bodies
//
// A soft body is the mesh's own vertices handed to XPBD as particles, so unlike
// every other body here it has no collider: the thing that collides *is* the
// drawing. That costs the two rules below, and they are the whole of what makes
// it different from a rigid body at a call site.
//
// **The node's transform belongs to the solver, and is a translation.** The
// particles are world-space, so the node is put at their average and the
// vertices are written relative to it. `object.position` is therefore the jelly's
// centre and reads back honestly; its rotation and scale are the identity and
// stay there, because a rotation applied on top of world-space vertices would
// turn the drawing away from the simulation.
//
// **Its copy of the mesh is its own.** Two nodes sharing one `BoxGeometry` share
// one vertex buffer and one draw call; a soft body writes vertices, so it cannot.
// It gets a bucket to itself — `Bucket.node` and `MeshPass.write_soft_vertices`
// are the two halves of that — and the thesis' one-shape-one-draw promise is
// bought out here on purpose, for the one kind of object that cannot keep it.

<*
 What a script asked for, before it becomes a `collision::SoftBody`.

 Every default is the library's own rather than a number invented here: zero
 compliance is inextensible links, `damping` is `create_softbody_from_mesh`'s
 0.99, and volume and bending are off because the constructor leaves them off.
*>
struct SoftSpec
{
	float mass;
	// XPBD compliance on the edge links, in metres per newton. Zero is a shape
	// that cannot stretch; larger is a shape that can.
	float softness;
	float damping;
	// Hold the enclosed volume — what makes a closed mesh a balloon rather than a
	// bag. Off unless asked for, and its own compliance beside it.
	bool volume;
	float volume_softness;
	// Resist folding along an edge, which is what stops a cloth creasing flat.
	bool bending;
	float bending_softness;
	float friction;
	float restitution;
}

<*
 One soft body, and the node whose mesh it deforms.
*>
struct SoftMesh
{
	NodeId node;
	sz id;
	// The mesh's vertices, and the solver's particles. They are not the same
	// number — see `weld_vertices`.
	uint count;
	uint particles;
	// Which particle each vertex rides. Vertices at the same point share one, so
	// this is what turns a `BoxGeometry`'s twenty-four corners into eight.
	uint[] map;

	<*
	 The per-particle normals, recomputed from the triangles after every step.

	 Host side rather than accumulated straight into the mapped vertex buffer,
	 because that buffer is write-combined: a normal is a sum over the triangles
	 touching a vertex, so building it in place would be a read-modify-write per
	 triangle corner over memory that is fast to write and very slow to read.
	*>
	Vec3[] normals;

	// Where the node was put — the particles' average — and the box the vertices
	// written relative to it fit in. `Scene.build_draw_list` culls against this
	// rather than the mesh's own bounds, which describe a shape that is no longer
	// the one being drawn.
	Vec3 center;
	collision::Aabb3 bounds;
}

fn void SoftMesh.drop(&self)
{
	if (self.normals.len > 0) mem::free(self.normals);
	if (self.map.len > 0) mem::free(self.map);
	self.normals = {};
	self.map = {};
}

<*
 A vertex position as a key that can be looked up: the three floats' own bits.

 Exact, rather than a tolerance. These are the file's own numbers and a duplicated
 corner is a *copy* of one rather than a second measurement of it, so anything
 looser would be a second thing to be wrong about. The one adjustment is negative
 zero, which is a different pattern from positive zero and the same point.
*>
struct WeldKey @local
{
	uint x;
	uint y;
	uint z;
}

<*
 A mix, for distribution only: `HashMap` still compares the three fields for the
 answer, so this only has to spread three float patterns across buckets rather
 than be injective.
*>
macro uint WeldKey.hash(self)
{
	ulong h = ((ulong)self.x * 0x9E3779B97F4A7C15) ^ ((ulong)self.y * 0xC2B2AE3D27D4EB4F);
	h ^= (ulong)self.z * 0x165667B19E3779F9;
	return (uint)(h ^ (h >> 32));
}

fn bool WeldKey.equals(self, WeldKey other) @operator(==) =>
	self.x == other.x && self.y == other.y && self.z == other.z;

alias WeldMap = HashMap {WeldKey, uint};

fn uint weld_bits(float value) @local => bitcast(value == 0 ? 0.0f : value, uint);

<*
 One particle per distinct point in the mesh, and which one each vertex rides.

 **Without this a soft `BoxGeometry` is six loose squares.** A box that shades
 with hard edges has four vertices per face and shares none of them, so the edges
 `create_softbody_from_mesh` takes from the triangles never cross from one face to
 the next and each face falls away on its own. Every generated shape here is built
 that way and so is most of what a modeller exports, which makes welding the
 difference between the verb working on a mesh and working on the handful of
 meshes that happen to be smooth-shaded.

 It also stops the seam of a UV sphere being a slit the solver can open.

 @param positions : `The mesh's vertices, in mesh order.`
 @param particles : `Filled with one entry per distinct point, in first-seen order.`
 @return `Vertex index to particle index, owned by the caller.`
*>
fn uint[] weld_vertices(Vec3[] positions, List{Vec3}* particles)
{
	uint[] map = mem::new_array(uint, positions.len);

	@pool()
	{
		WeldMap seen;
		seen.tinit();

		foreach (i, at : positions)
		{
			WeldKey key = { weld_bits(at.x), weld_bits(at.y), weld_bits(at.z) };
			uint? found = seen.get(key);
			if (try found)
			{
				map[i] = found;
				continue;
			}
			uint slot = (uint)particles.len();
			particles.push(at);
			seen.set(key, slot);
			map[i] = slot;
		}
	};

	return map;
}

<*
 The centre, the bounds and the normals, from wherever the particles are now.

 @return `False when the body has left the simulation — see Physics.evict_diverged.`
*>
fn bool SoftMesh.refresh(&self, collision::SoftBody* body)
{
	sz count = body.positions.len();
	if (count == 0 || count != self.normals.len) return false;

	Vec3 sum = { 0, 0, 0 };
	foreach (at : body.positions) sum += at;
	Vec3 center = sum / (float)count;
	if (!math::is_finite(center.x) || !math::is_finite(center.y) || !math::is_finite(center.z)) return false;
	if (center.length_sq() > DIVERGED_DISTANCE_SQ) return false;

	self.center = center;
	self.bounds = { .min = body.positions[0] - center, .max = body.positions[0] - center };
	foreach (at : body.positions)
	{
		Vec3 local = at - center;
		self.bounds.min = math::min(self.bounds.min, local);
		self.bounds.max = math::max(self.bounds.max, local);
	}

	// Area-weighted, which is what the un-normalized cross product already is:
	// a big triangle should have more say in a shared vertex's normal than a
	// sliver does.
	foreach (&normal : self.normals) *normal = { 0, 0, 0 };
	foreach (triangle : body.triangles)
	{
		uint i0 = triangle[0];
		uint i1 = triangle[1];
		uint i2 = triangle[2];
		if (i0 >= count || i1 >= count || i2 >= count) continue;
		Vec3 face = (body.positions[i1] - body.positions[i0]).cross(body.positions[i2] - body.positions[i0]);
		self.normals[i0] += face;
		self.normals[i1] += face;
		self.normals[i2] += face;
	}
	foreach (&normal : self.normals)
	{
		// A vertex no triangle reached, or one whose triangles cancelled out. Up,
		// rather than a zero the shader would light as black.
		*normal = normal.length_sq() > 1e-12f ? normal.normalize() : (Vec3) { 0, 1, 0 };
	}
	return true;
}

<*
 The soft body on a node, or null.

 The early return is what makes it free: every drawable node asks this once a
 frame through `Scene.build_draw_list`, and a scene with no soft bodies — which
 is nearly every scene — pays one compare for the whole list.
*>
fn SoftMesh* Physics.soft_for(&self, NodeId node)
{
	if (self.softs.len() == 0) return null;
	foreach (&soft : self.softs)
	{
		if (soft.node == node) return soft;
	}
	return null;
}

<*
 Turns a node's mesh into a soft body.

 The particles are the mesh's own vertices put through the node's world matrix,
 so whatever a script scaled, turned and placed is baked into the starting shape
 and the node is then reset to a bare translation. The links between them are the
 mesh's edges — `create_softbody_from_mesh` walks the triangles for them — which
 is why the shape a soft body holds is the shape it was modelled as.

 Refused on a skinned mesh. A character's vertices are already owned, by the
 palette the vertex shader blends with, and two things writing one set of
 positions is a picture that depends on which ran last.

 @param spec : `The tuning, already defaulted by the prelude.`
*>
fn void? Physics.add_soft(&self, Scene* scene, Assets* assets, NodeId node_id, SoftSpec spec)
{
	self.open();

	Node* node = scene.node(node_id);
	if (node == null) return NODE_HAS_NO_MESH~;
	if (!(node.parent == scene.root)) return NODE_IS_NOT_TOP_LEVEL~;
	if (!node.asset.is_set()) return NODE_HAS_NO_MESH~;

	GpuMesh* slot = assets.mesh(node.asset, node.mesh);
	if (slot == null) return NODE_HAS_NO_MESH~;
	if (slot.has_skin) return SOFT_IS_SKINNED~;
	// `hull_positions` is the picking tree's copy of the mesh, in mesh order, so
	// particle i is vertex i and the index buffer needs no translation at all.
	if (slot.hull_positions.len == 0 || slot.hull_triangles.len == 0) return SOFT_HAS_NO_POINTS~;

	// One or the other, never both: a rigid body would move the node the soft
	// body is writing vertices under.
	self.remove(node_id);
	self.remove_soft(node_id);

	sz id = self.next_id++;

	// One particle per distinct point rather than one per vertex, and the map from
	// the mesh's vertices onto them. Kept, because the write-back needs it every
	// frame — `MeshPass.write_soft_vertices`.
	List{Vec3} points;
	points.init(mem, slot.hull_positions.len);
	defer points.free();
	uint[] map = weld_vertices(slot.hull_positions, &points);

	@pool()
	{
		// On the temp arena, because `create_softbody_from_mesh` copies both lists
		// into the body it returns and nothing keeps this.
		collision::Mesh source;
		source.vertices.init(tmem, points.len());
		source.triangles.init(tmem, slot.hull_triangles.len);
		// Into world space here rather than in the weld, so the weld compares the
		// file's own numbers and a scaled or turned node cannot make two copies of
		// one corner miss each other.
		//
		// The node's *local* matrix, which is its world matrix: a body-backed node
		// is a child of the scene root. Reading `node.world` would be the same
		// answer one frame later and the identity right now, because nothing has
		// walked the graph since the script placed this.
		foreach (point : points) source.vertices.push(transform_point(node.local_matrix(), point));
		foreach (triangle : slot.hull_triangles)
		{
			source.triangles.push({ map[triangle[0]], map[triangle[1]], map[triangle[2]] });
		}

		collision::SoftBody body = collision::create_softbody_from_mesh(&source, spec.mass, id, mem);
		if (spec.softness > 0) body.set_distance_compliance(spec.softness);
		body.damping = spec.damping;
		body.material.static_friction = spec.friction;
		body.material.dynamic_friction = spec.friction;
		body.material.restitution = spec.restitution;
		// After the positions are in, both of them: the rest volume and the rest
		// dihedral angles are measured off the particles as they stand.
		if (spec.volume) body.enable_volume_preservation(spec.volume_softness);
		if (spec.bending) body.enable_bending(spec.bending_softness);

		self.world.add_softbody(body);
	};

	SoftMesh record = {
		.node = node_id,
		.id = id,
		.count = (uint)slot.hull_positions.len,
		.particles = (uint)points.len(),
		.map = map,
	};
	record.normals = mem::new_array(Vec3, (sz)record.particles);
	self.softs.push(record);

	// Filled before the first step so the very first frame draws the shape rather
	// than a mesh of zeroes.
	self.settle_soft(scene, &self.softs[self.softs.len() - 1]);
}

<*
 Puts one soft body's node where the particles say, and refreshes what the
 renderer reads.
*>
fn bool Physics.settle_soft(&self, Scene* scene, SoftMesh* record)
{
	collision::SoftBody*? body = self.world.find_softbody(record.id);
	if (catch body) return false;
	if (!record.refresh(body)) return false;

	Node* node = scene.node(record.node);
	if (node == null) return true;
	node.position = record.center;
	node.rotation = NO_ROTATION;
	node.scale = { 1, 1, 1 };
	scene.mark_moved(record.node);
	return true;
}

<*
 Takes a node's soft body away. False when it had none.

 The node keeps the position the last step left it at and its mesh goes back to
 the shape it was modelled as — the vertices it draws are the asset's own again
 the moment nothing is overriding them.
*>
fn bool Physics.remove_soft(&self, NodeId node)
{
	if (!self.opened) return false;

	foreach (i, &record : self.softs)
	{
		if (!(record.node == node)) continue;
		self.world.remove_softbody(record.id);
		record.drop();
		self.softs.remove_at(i);
		return true;
	}
	return false;
}

<*
 Pins one particle to a world point, or to nothing.

 `at` is where it is held. A pin is absolute — the particle is put there after
 every substep — so moving a pin between frames is how a soft body is dragged,
 and it is the only way a script pushes one directly.

 @return `False when the node has no soft body or the index names no particle.`
*>
fn bool Physics.pin_soft(&self, NodeId node, sz particle, Vec3 at)
{
	SoftMesh* record = self.soft_for(node);
	if (record == null) return false;

	collision::SoftBody*? body = self.world.find_softbody(record.id);
	if (catch body) return false;
	if (particle < 0 || particle >= body.positions.len()) return false;

	body.wake();
	body.pin_particle(particle, at);
	return true;
}

<*
 Lets a pinned particle go, and gives it back a mass.

 @param mass : `What the particle weighs once it is free. The body's own per-particle share, unless a script says otherwise.`
*>
fn bool Physics.unpin_soft(&self, NodeId node, sz particle, float mass)
{
	SoftMesh* record = self.soft_for(node);
	if (record == null) return false;

	collision::SoftBody*? body = self.world.find_softbody(record.id);
	if (catch body) return false;
	if (particle < 0 || particle >= body.positions.len()) return false;

	body.wake();
	body.unpin_particle(particle, mass);
	return true;
}

<*
 The solver's particles for a node, or an empty slice.

 World space, and the same order the mesh's vertices are in — so a script that
 wants to pin the top of a flag finds the index by looking at the geometry it
 built.
*>
fn Vec3[] Physics.soft_points(&self, NodeId node)
{
	SoftMesh* record = self.soft_for(node);
	if (record == null) return {};

	collision::SoftBody*? body = self.world.find_softbody(record.id);
	if (catch body) return {};
	return body.positions.array_view();
}
