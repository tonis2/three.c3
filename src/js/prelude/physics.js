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
import { asTriple } from './math.js';
import { liveObject } from './scene.js';

const H = globalThis.__three;

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
	};
}
