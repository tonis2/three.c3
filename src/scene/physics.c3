
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
	NODE_IS_NOT_TOP_LEVEL,
	// A heightfield collider was asked for on a node whose mesh is not terrain.
	// There is no grid to take, and approximating one would be a collider that
	// looks right and behaves wrongly.
	NODE_IS_NOT_TERRAIN;

// What a script is told when it writes a transform the solver owns. One string
// rather than two copies, because it is raised from both transform doors and a
// sentence that drifts between them is worse than no sentence.
const String PHYSICS_OWNS_TRANSFORM =
	"this object's transform belongs to the physics solver — a dynamic body is "
	"moved by the world, not by a script. Make the body kinematic to drive it "
	"yourself, or three.physics.remove(object) first.";

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
	PhysicsBody* body = self.body_for(node);
	if (body == null) return false;
	return body.kind == BodyKind.DYNAMIC;
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

	return self.diverged.len() - before;
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
