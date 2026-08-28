// three.c3 — the physics verbs, bound to the Scene that owns the world.
//
// A `Physics` world belongs to a `Scene` rather than to the process, because a
// body names a node and a node belongs to one graph. That is what makes a level
// transition cost nothing: the next level's bodies are built while it is off
// screen, and activating it shows a world already standing up.
//
// **Only the rendered scene is stepped.** Bodies in a scene nobody is looking at
// are correct and motionless — the frame advances one world, and stepping every
// world would charge a game for the levels it is not playing.
//
// `three.physics` is a view onto whichever scene is being rendered; `scene.physics`
// is the one that belongs to a scene.
//
// Three kinds of thing live here. A **body** is a collider the solver moves and a
// script reads back. A **joint** holds two bodies together and is the only thing
// here addressed by an id rather than by an object, because it is not a node. A
// **soft body** is the object's own vertices simulated as particles — it has no
// collider, its transform belongs to the solver, and it is the one thing in this
// file that costs a draw call of its own.
import { asTriple } from './math.js';
import { liveObject } from './scene.js';

const H = globalThis.__three;

// The four shorthand words, as the limit lists they stand for. Every one of
// them is three linear axes and three angular axes accounted for; what makes a
// hinge a hinge is which one is left out, and `free` is the side that a
// `range` option would then bound.
const JOINT_TYPES = {
	fixed: { linear: [0, 1, 2], angular: [0, 1, 2], free: null },
	point: { linear: [0, 1, 2], angular: [], free: null },
	hinge: { linear: [0, 1, 2], angular: [1, 2], free: 'angularAxes' },
	slider: { linear: [1, 2], angular: [0, 1, 2], free: 'linearAxes' },
};

// The limits a `type` stands for, plus its `range` if it was given one.
function jointTypeLimits(desc) {
	const type = desc.type === undefined ? 'fixed' : String(desc.type);
	const shape = JOINT_TYPES[type];
	if (!shape) {
		throw new TypeError(
			`'${type}' is not a joint type — it is one of ${Object.keys(JOINT_TYPES).join(', ')}, `
			+ 'or give a limits array of your own'
		);
	}

	const limits = [];
	if (shape.linear.length) limits.push({ linearAxes: shape.linear });
	if (shape.angular.length) limits.push({ angularAxes: shape.angular });
	if (desc.range === undefined) return limits;

	if (!shape.free) {
		throw new RangeError(
			`a '${type}' joint holds every axis, so there is nothing for range to bound — `
			+ 'a hinge or a slider is what has a free axis'
		);
	}
	if (!Array.isArray(desc.range) || desc.range.length !== 2) {
		throw new TypeError('joint range is [min, max]');
	}
	const [min, max] = desc.range.map(Number);
	if (!Number.isFinite(min) || !Number.isFinite(max)) {
		throw new TypeError(`joint range must be finite numbers, not [${desc.range}]`);
	}
	if (min > max) throw new RangeError(`joint range is [min, max] and ${min} > ${max}`);
	if (min === 0 && max === 0) {
		throw new RangeError(
			'a range of [0, 0] would LOCK the free axis rather than bound it, which welds the joint '
			+ 'shut. Leave range out for a hinge that swings freely or a slider that runs the whole way'
		);
	}
	limits.push({ [shape.free]: [0], min, max });
	return limits;
}

// One axis list to the bit mask the host reads: axis 0 is bit 1, 1 is bit 2,
// 2 is bit 4. There are three axes and nothing else is one.
function jointAxisMask(axes, where) {
	if (!Array.isArray(axes)) throw new TypeError(`${where} is an array of axis numbers`);
	let mask = 0;
	for (const axis of axes) {
		const i = Number(axis);
		if (i !== 0 && i !== 1 && i !== 2) {
			throw new RangeError(`${where} names axis ${axis}; a joint frame has axes 0, 1 and 2`);
		}
		mask |= 1 << i;
	}
	if (mask === 0) throw new RangeError(`${where} names no axis, so the limit holds nothing`);
	return mask;
}

// The limit list, flattened to what the host reads: six floats each, kind
// first — 0 linear, 1 angular. A limit naming both sides is two rows, which is
// how the glTF loader splits one too.
function packJointLimits(limits) {
	const rows = [];
	for (const limit of limits) {
		if (!limit || typeof limit !== 'object') {
			throw new TypeError('each joint limit is { linearAxes, angularAxes, min, max, stiffness, damping }');
		}
		const min = limit.min === undefined ? 0 : Number(limit.min);
		const max = limit.max === undefined ? 0 : Number(limit.max);
		if (!Number.isFinite(min) || !Number.isFinite(max)) {
			throw new TypeError(`a joint limit's min and max must be finite numbers, not ${min} and ${max}`);
		}
		if (min > max) throw new RangeError(`a joint limit is min then max, and ${min} > ${max}`);

		const stiffness = limit.stiffness === undefined ? 0 : Number(limit.stiffness);
		const damping = limit.damping === undefined ? 0 : Number(limit.damping);

		if (limit.linearAxes === undefined && limit.angularAxes === undefined) {
			throw new TypeError('a joint limit needs linearAxes or angularAxes — it holds nothing otherwise');
		}
		if (limit.linearAxes !== undefined) {
			rows.push(0, jointAxisMask(limit.linearAxes, 'linearAxes'), min, max, stiffness, damping);
		}
		if (limit.angularAxes !== undefined) {
			rows.push(1, jointAxisMask(limit.angularAxes, 'angularAxes'), min, max, stiffness, damping);
		}
	}
	return new Float32Array(rows);
}

// One scene's physics verbs. Called by the `Scene` constructor.
export function makeScenePhysics(scene) {
	return {
		// Give an object a body. The description is `object.body` if it has
		// one, and `options` wins over it, so a scene can be described once
		// and tweaked at the call.
		//
		// `shape` is one of 'box', 'sphere', 'capsule', 'hull' or
		// 'heightfield', and every one of them comes from the mesh rather
		// than from numbers you supply. 'heightfield' is the odd one and
		// is the reason it is worth naming here: it is only for a
		// TerrainGeometry, and it is the terrain's own grid of heights
		// handed to the solver as one shape — so a body rests on the same
		// surface `terrain.heightAt(x, z)` reports, at any slope, with one
		// collider instead of a chain of invisible boxes under a path that
		// had to be flat to have them.
		add(object, options) {
			const target = liveObject(object, 'three.physics.add');
			const desc = Object.assign({}, object.body || {}, options || {});

			const shape = desc.shape === undefined ? 'box' : String(desc.shape);
			const mass = desc.mass === undefined ? 1 : Number(desc.mass);
			const friction = desc.friction === undefined ? 0.5 : Number(desc.friction);
			const restitution = desc.restitution === undefined ? 0.2 : Number(desc.restitution);

			for (const [name, value] of [['mass', mass], ['friction', friction], ['restitution', restitution]]) {
				if (!Number.isFinite(value)) {
					throw new TypeError(`body.${name} must be a finite number, not ${value}`);
				}
			}
			if (mass < 0) throw new RangeError(`body.mass cannot be negative — ${mass} is not a weight`);

			// One word out of four, decided here rather than by the host so
			// that `mass: 0` means the same thing it means in every other
			// engine: something that does not move.
			const kind = desc.trigger ? 'trigger'
				: desc.kinematic ? 'kinematic'
				: (desc.static || mass === 0) ? 'static'
				: 'dynamic';

			H.physicsAdd(target[0], target[1], kind, shape, mass, friction, restitution);
			object.body = { shape, mass, friction, restitution, kind };
			object._solverOwned = kind === 'dynamic';
			return object;
		},

		// Take the body away. False when it had none, so removing twice is
		// not an error.
		remove(object) {
			const target = liveObject(object, 'three.physics.remove');
			if (object.body) object.body = null;
			object._solverOwned = false;
			return H.physicsRemove(target[0], target[1]);
		},

		// [x, y, z], y-up. An array rather than a live Vector3 because it
		// is a world setting and not a transform: writing to a component of
		// something read back would look like it did something.
		get gravity() { return H.physicsGravityGet(scene._sid); },
		set gravity(value) {
			const [x, y, z] = asTriple(value, 'three.physics.gravity');
			H.physicsGravitySet(scene._sid, x, y, z);
		},

		// How many bodies the world holds.
		get count() { return H.physicsCount(scene._sid); },

		// ---------------------------------------------------------------
		// Steering a body
		//
		// Functions taking the object rather than properties on it, because
		// a velocity belongs to the body and an object may not have one —
		// `mesh.velocity` would be a property that exists on everything and
		// means something on almost nothing.
		//
		// **setVelocity assigns and applyImpulse adds**, which is the whole
		// distinction at a call site. A character sets its velocity every
		// frame from the keys that are down, because what it wants is a
		// speed. A jump, an explosion or a bat applies an impulse, because
		// what it wants is a change to whatever the speed already was.
		// Using an impulse where a velocity was meant gives something that
		// accelerates forever.

		// [lx, ly, lz, ax, ay, az] — linear in units per second, angular in
		// radians per second — or null when the object has no body.
		//
		// Null rather than a throw because this gets asked in a loop over
		// things that may or may not have bodies, and answering with both
		// velocities at once because a script that wants one usually wants
		// the other in the same breath.
		velocity(object) {
			const target = liveObject(object, 'three.physics.velocity');
			return H.physicsVelocityGet(target[0], target[1]);
		},

		// World units per second. Only a dynamic body can be given one: a
		// static body's inverse mass is zero and a kinematic body is driven
		// by the transform a script writes, so both throw and say which.
		setVelocity(object, value) {
			const target = liveObject(object, 'three.physics.setVelocity');
			const [x, y, z] = asTriple(value, 'three.physics.setVelocity');
			H.physicsLinearSet(target[0], target[1], x, y, z);
			return object;
		},

		// Radians per second about each world axis; the vector's length is
		// the rate.
		setAngularVelocity(object, value) {
			const target = liveObject(object, 'three.physics.setAngularVelocity');
			const [x, y, z] = asTriple(value, 'three.physics.setAngularVelocity');
			H.physicsAngularSet(target[0], target[1], x, y, z);
			return object;
		},

		// A push, in mass times velocity, so the same impulse moves a heavy
		// thing less. `at` is an offset from the body's centre in world
		// axes, not a world position: give one and the push also tumbles
		// the body, leave it out and it is a pure shove.
		applyImpulse(object, impulse, at) {
			const target = liveObject(object, 'three.physics.applyImpulse');
			const [x, y, z] = asTriple(impulse, 'three.physics.applyImpulse');
			const [px, py, pz] = at === undefined
				? [0, 0, 0]
				: asTriple(at, 'three.physics.applyImpulse(object, impulse, at)');
			H.physicsImpulse(target[0], target[1], x, y, z, px, py, pz);
			return object;
		},

		// A spin with no shove. Separate from an off-centre applyImpulse
		// because "make this rotate" should not require solving for an
		// offset and a force that happen to produce the spin you wanted.
		applyTorqueImpulse(object, impulse) {
			const target = liveObject(object, 'three.physics.applyTorqueImpulse');
			const [x, y, z] = asTriple(impulse, 'three.physics.applyTorqueImpulse');
			H.physicsTorqueImpulse(target[0], target[1], x, y, z);
			return object;
		},

		// ---------------------------------------------------------------
		// Joints
		//
		// A joint is a LIST OF LIMITS: some of the joint frame's axes,
		// held to some range. That is glTF's description of one
		// (KHR_physics_rigid_bodies) and it is what the solver stores, so
		// a limit read out of a .glb and a limit written here are the same
		// object and neither needs translating.
		//
		//   three.physics.joint(door, frame, {
		//     axis: [0, 1, 0],
		//     limits: [
		//       { linearAxes: [0, 1, 2] },                 // pinned
		//       { angularAxes: [1, 2] },                   // no twist, no tilt
		//       { angularAxes: [0], min: -1.4, max: 1.4 }, // swings, this far
		//     ],
		//   })
		//
		// AXIS 0 IS `axis`; 1 and 2 are perpendicular to it and to each
		// other, derived from it, so a limit naming [1, 2] means "the
		// plane the axle is normal to" whichever way the axle points.
		//
		// NO RANGE IS A LOCK. A limit with no min and max holds its axes
		// at zero, which is glTF's default for both fields. It is the
		// opposite of what "no limit" sounds like and it is worth knowing
		// before writing one.
		//
		// `stiffness` IS A SPRING CONSTANT AND 0 IS THE RIGID END. The
		// solver reads it as (1 / stiffness) / dt^2 and special-cases 0 to
		// no give at all, so bigger is stiffer, 0 is a wall, and a small
		// positive number is the softest thing there is. Enough to be felt
		// on a one-kilogram prop at 60 Hz is in the low thousands.
		// `damping` is carried into the joint and is NOT READ by the
		// solver yet; it is accepted so that a limit out of a .glb survives
		// being passed straight in.
		//
		// `type` is shorthand for the four lists people actually want, and
		// is expanded here rather than by the host — so anything it can say
		// can also be said by hand, and it is the only thing in this file
		// that knows what a hinge is.

		// Join two body-backed objects and answer with the joint's id,
		// which is what removeJoint takes.
		//
		// { type: 'fixed' | 'point' | 'hinge' | 'slider',  // or limits, below
		//   limits: [{ linearAxes, angularAxes, min, max, stiffness, damping }],
		//   range: [min, max],   // the shorthand's one free axis
		//   pivot: [x, y, z],    // world; default is halfway between
		//   axis: [x, y, z],     // axis 0 of the frame; default [0, 1, 0]
		//   stiffness: 0,        // the spring for limits that name none; 0 is rigid
		//   damping: 0,          // carried, and not read by the solver yet
		//   collide: false }     // whether the two still collide with each other
		//
		// THE JOINT IS MADE WHERE THE BODIES ARE: the pivot defaults to the
		// midpoint between them and the relative orientation is whatever
		// they are turned to right now. So place both objects, then join
		// them, rather than describing the rest pose in numbers.
		joint(a, b, options) {
			const first = liveObject(a, 'three.physics.joint');
			const second = liveObject(b, 'three.physics.joint');
			const desc = options || {};

			const [ax, ay, az] = desc.axis === undefined
				? [0, 1, 0]
				: asTriple(desc.axis, 'three.physics.joint(a, b, { axis })');
			const hasPivot = desc.pivot !== undefined;
			const [px, py, pz] = hasPivot
				? asTriple(desc.pivot, 'three.physics.joint(a, b, { pivot })')
				: [0, 0, 0];

			const stiffness = desc.stiffness === undefined ? 0 : Number(desc.stiffness);
			const damping = desc.damping === undefined ? 0 : Number(desc.damping);
			for (const [name, value] of [['stiffness', stiffness], ['damping', damping]]) {
				if (!Number.isFinite(value) || value < 0) {
					throw new TypeError(`joint.${name} must be a finite number that is not negative, not ${value}`);
				}
			}

			const limits = desc.limits === undefined ? jointTypeLimits(desc) : desc.limits;
			if (!Array.isArray(limits) || limits.length === 0) {
				throw new TypeError('joint limits are a non-empty array of { linearAxes, angularAxes, min, max }');
			}

			return H.physicsJoint(
				first[0], first[1], second[0], second[1],
				hasPivot, px, py, pz, ax, ay, az,
				!!desc.collide, stiffness, damping,
				packJointLimits(limits).buffer
			);
		},

		// Take one joint away, by the id joint() answered with. False when
		// the id names nothing, so removing twice is not an error. Removing
		// either body removes the joints holding it.
		removeJoint(id) {
			return H.physicsJointRemove(scene._sid, Number(id));
		},

		// ---------------------------------------------------------------
		// Soft bodies
		//
		// The object's own vertices, handed to the solver as particles held
		// together by the mesh's edges. So a soft body has no collider and
		// no shape option: the thing that collides IS the drawing, and how
		// it deforms is decided by how the mesh was modelled.
		//
		// Two things follow, and they are the whole of what makes it
		// different from a rigid body at a call site. Its transform belongs
		// to the solver — object.position reads the particles' average and
		// writing it throws, exactly as for a dynamic body. And it costs a
		// draw call of its own: two copies of one BoxGeometry are one draw,
		// but two soft ones are two, because each is writing its own
		// vertices.

		// Make this object a soft body and answer with the object.
		//
		// { mass: 1,
		//   softness: 0,        // how far the edges stretch; 0 cannot
		//   damping: 0.99,      // velocity kept per substep
		//   volume: false,      // hold the enclosed volume — a balloon rather than a bag
		//   bending: false,     // resist folding — what stops cloth creasing flat
		//   friction: 0.5, restitution: 0.2 }
		//
		// `volume` and `bending` take true or a compliance number of their
		// own; true is the library's default for each.
		soft(object, options) {
			const target = liveObject(object, 'three.physics.soft');
			const desc = Object.assign({}, object.body || {}, options || {});

			const mass = desc.mass === undefined ? 1 : Number(desc.mass);
			const softness = desc.softness === undefined ? 0 : Number(desc.softness);
			const damping = desc.damping === undefined ? 0.99 : Number(desc.damping);
			const friction = desc.friction === undefined ? 0.5 : Number(desc.friction);
			const restitution = desc.restitution === undefined ? 0.2 : Number(desc.restitution);

			for (const [name, value] of [
				['mass', mass], ['softness', softness], ['damping', damping],
				['friction', friction], ['restitution', restitution],
			]) {
				if (!Number.isFinite(value)) {
					throw new TypeError(`body.${name} must be a finite number, not ${value}`);
				}
			}
			if (mass <= 0) {
				throw new RangeError(
					`a soft body's mass is shared out over its particles, so it cannot be ${mass} — `
					+ 'there is no static soft body, and mass 0 would give every particle infinite weight'
				);
			}

			// true means "on, at the library's own compliance"; a number is
			// that compliance. Two options rather than four, because "on"
			// is what a script wants to say nine times out of ten.
			const volume = desc.volume !== undefined && desc.volume !== false;
			const bending = desc.bending !== undefined && desc.bending !== false;
			const volumeSoftness = typeof desc.volume === 'number' ? desc.volume : 0;
			const bendingSoftness = typeof desc.bending === 'number' ? desc.bending : 0.001;

			H.physicsSoftAdd(
				target[0], target[1], mass, softness, damping,
				volume, volumeSoftness, bending, bendingSoftness, friction, restitution
			);
			object.body = { soft: true, mass, softness, damping, friction, restitution };
			object._solverOwned = true;
			return object;
		},

		// Take the soft body away. The mesh goes back to the shape it was
		// modelled as, where the last step left it. False when it had none.
		removeSoft(object) {
			const target = liveObject(object, 'three.physics.removeSoft');
			if (object.body && object.body.soft) object.body = null;
			object._solverOwned = false;
			return H.physicsSoftRemove(target[0], target[1]);
		},

		// How many particles a soft body has. ONE PER DISTINCT POINT in the
		// mesh, not one per vertex: a BoxGeometry has twenty-four vertices
		// and eight particles, because a box that shades with hard edges
		// stores each corner three times and the solver has to treat them
		// as one or the box falls into six loose squares. 0 for an object
		// that is not a soft body.
		softCount(object) {
			const target = liveObject(object, 'three.physics.softCount');
			return H.physicsSoftCount(target[0], target[1]);
		},

		// The particles, in world space, as a Float32Array of count * 3 —
		// x, y, z, x, y, z. This is how a script finds the index to pin:
		// read them and pick the ones you want, usually by position, since
		// there is no other name a particle has.
		//
		// `into` is optional and lets you reuse one array across frames,
		// the way texture.read does; without it one is allocated per call.
		points(object, into) {
			const target = liveObject(object, 'three.physics.points');
			const count = H.physicsSoftCount(target[0], target[1]);
			if (count === 0) return new Float32Array(0);

			const out = into instanceof Float32Array && into.length === count * 3
				? into
				: new Float32Array(count * 3);
			H.physicsSoftPoints(target[0], target[1], out.buffer);
			return out;
		},

		// Hold one particle at a world point — or where it already is, with
		// no third argument. This is the only way to push a soft body: it
		// has no velocity to set and no centre to shove, so a script drags
		// one by moving its pins. Pinning is absolute and is reapplied
		// after every substep, so a pin moved each frame carries the body.
		pin(object, particle, at) {
			const target = liveObject(object, 'three.physics.pin');
			const [x, y, z] = at === undefined ? [0, 0, 0] : asTriple(at, 'three.physics.pin(object, i, at)');
			return H.physicsSoftPin(target[0], target[1], particle | 0, at !== undefined, x, y, z);
		},

		// Let a pinned particle go. `mass` is what it weighs afterwards and
		// defaults to the body's own per-particle share.
		unpin(object, particle, mass) {
			const target = liveObject(object, 'three.physics.unpin');
			const count = H.physicsSoftCount(target[0], target[1]);
			const share = mass === undefined
				? (object.body && object.body.mass ? object.body.mass / Math.max(1, count) : 1)
				: Number(mass);
			return H.physicsSoftUnpin(target[0], target[1], particle | 0, share);
		},
	};
}
