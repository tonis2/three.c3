<*
 Tracked classes and rules — §23.

	`c3c test --trust=full --test-noleak --test-filter three_tests::entity`

 **The failures this can have are the quiet kind**, and they come in two shapes.

 A tracked class owns three things only visible from outside — a node in the
 scene, a body in the solver, and an entry in the object map — and `remove` takes
 all three away at once. Any one left behind throws nothing: a body with no mesh
 shoves the player out of empty space, a mesh with no body draws a crate that was
 broken, and a stale map entry answers `of()` with something that is not there.

 The columns add a second shape. A column is a WINDOW and not a copy, so the test
 that matters is that the host wrote the script's own bytes — a gather that
 quietly crept back in would pass every test that only checks values. And a
 compaction moves floats underneath live instances: get that wrong and one
 entity in fifty reads another's velocity, which is indistinguishable from bad
 steering.

 The rules have a third: dispatch is on a PAIR, so a matcher that silently never
 matches is a rule that looks registered and does nothing.
*>
module three_tests::entity;

import three;
import vk;
import std::core::test;

macro @with_gpu_js(; @body(three::JsRuntime* run))
{
	vk::Instance instance = three::create_instance(false, headless: true)!!;
	defer instance.free();

	three::Renderer renderer;
	renderer.init(instance, (vk::SurfaceKHR)null, 200, 150)!!;
	defer renderer.free();

	renderer.pass.init(&renderer.gpu, &renderer.target)!!;

	three::JsRuntime runtime;
	runtime.open(&renderer.pass, &renderer)!!;
	defer runtime.close();

	@body(&runtime);
}

macro String @value(three::JsRuntime* run, String source, String what)
{
	three::RunResult result = run.run(source);
	defer result.free();
	test::@check(result.ok, "%s: %s", what, result.error);
	return result.value.copy(tmem);
}

// Run `frames` ticks with a hand-fed clock, then read a global the script left.
macro String @after_frames(three::JsRuntime* run, String source, int frames, String read, String what)
{
	@value(run, source, what);
	double at = 0;
	for (int i = 0; i < frames; i++)
	{
		at += 1000.0 / 60.0;
		run.tick(at);
	}
	return @value(run, read, "the reading script ran");
}

// ============================================================================
// Storage
// ============================================================================

<*
 A spawn puts a node in the scene and a REAL body in the solver, and `new` does
 not.

 Counting bodies would pass for a `physicsAdd` that filed a handle and did
 nothing, so the check is that the crate FALLS: a dynamic box spawned in the air
 lands on a static floor, which is a claim about the solver rather than about the
 bookkeeping in front of it.

 The `new` half is the other direction. An untracked instance has no slot, no
 body and no place in the live list, and every one of those failures is silent —
 so the Proxy `three.track` answers with refuses it out loud, and this is the
 test that the refusal is actually wired up rather than merely written.
*>
fn void a_spawn_places_a_node_and_a_body_and_new_is_refused() @test
{
	@with_gpu_js(; three::JsRuntime* run)
	{
		String built = @value(run, `
			const scene = new three.Scene();
			const floor = new three.Mesh(new three.BoxGeometry(20, 1, 20));
			floor.position.y = -0.5;
			scene.add(floor);
			three.physics.add(floor, { shape: 'box', mass: 0 });

			globalThis.Crate = three.track(class Crate {
				constructor(at, variant) {
					this.variant = variant;
					this.object = new three.Mesh(new three.BoxGeometry(1, 1, 1));
					this.object.position.set(at[0], at[1], at[2]);
				}
			}, { body: { shape: 'box', mass: 5, friction: 0.7 } });

			globalThis.c = Crate.spawn([0, 6, 0], 'tnt');
			let refused = null;
			try { new Crate([0, 0, 0], 'x'); } catch (e) { refused = e.message.slice(0, 12); }
			return [
				three.physics.count,
				scene.getObjectByName('Crate#0') === c.object,
				c.variant, Crate.count, Crate.trackName, refused,
			];
		`, "the spawn script ran");

		test::@check(built == "[2,true,\"tnt\",1,\"Crate\",\"new Crate() \"]",
			"a spawn places a node, a body and an instance, and new is refused; got %s", built);

		// Two seconds at the host's fixed 60 Hz — `test/physics_test.c3`'s
		// fixture for dropping a ball.
		for (int i = 1; i <= 120; i++) run.tick((double)i * (1000.0 / 60.0));

		String landed = @value(run, "return [c.object.position.y < 1.5, c.object.position.y > 0];",
			"the reading script ran");
		test::@check(landed == "[true,true]",
			"and the body is the solver's, not a handle in a list; got %s", landed);
	};
}

<*
 A column is a WINDOW over shared memory, and the host writes the script's bytes.

 This is the whole claim of §23 and the reason the design is not a gather. The
 check is deliberately not "the numbers came back right" — a staging copy would
 satisfy that. It is that `three.steer`, handed `Class.column('motion')`, changed
 the floats that `instance.motion` reads, with nothing copied in either
 direction: `bind_query.c3`'s `typed_view` hands C3 a pointer into QuickJS's own
 buffer, so the two names are the same memory or the design is wrong.

 The subarray identity is asserted too, because a getter that answered with a
 fresh copy each time would pass the value check and fail every game.
*>
fn void a_column_is_a_window_and_the_host_writes_through_it() @test
{
	@with_gpu_js(; three::JsRuntime* run)
	{
		String value = @value(run, `
			const scene = new three.Scene();
			const Critter = three.track(class Critter {
				constructor(x) { this.position[0] = x; this.position[1] = 1; }
			}, { columns: { position: 3, motion: 3 }, capacity: 8 });

			const a = Critter.spawn(1);
			const b = Critter.spawn(2);

			const column = Critter.column('position');
			// The instance's window and the class's column are one allocation.
			const sameBuffer = a.position.buffer === column.buffer;
			const atSlot = [column[0], column[3]];
			a.position[0] = 7;                       // write through the window
			const throughWindow = column[0];

			// The host, handed the motion column, must change what b.motion reads.
			const before = b.motion[0];
			three.steer(Critter.column('position'), Critter.column('motion'), { goal: [100, 0, 0], maxSpeed: 4 });
			const after = b.motion[0];

			let refusedAssign = null;
			try { a.position = [0, 0, 0]; } catch (e) { refusedAssign = e.message.slice(0, 16); }

			return [
				sameBuffer, atSlot, throughWindow, column.length,
				before === 0, after > 0, refusedAssign,
			];
		`, "the column script ran");

		test::@check(value == "[true,[1,2],7,6,true,true,\"Critter.position\"]",
			"a column is one buffer the host writes through, and cannot be reassigned; got %s", value);
	};
}

<*
 A compaction moves the floats and every survivor still reads its own.

 The view is a function of the SLOT and not of the instance, which is what makes
 this cheap — the data moves down, the instance's slot number changes, and the
 getter picks up the right window with nothing to re-seat. Get it backwards and
 the entity after a hole reads its neighbour's position, which looks like bad
 steering rather than like a bookkeeping bug.

 Stable rather than a swap-remove, so the order of the survivors is the order
 they were spawned in: `three.steer`'s separation reads neighbours out of this
 array, and a crowd that reordered itself on every death would behave differently
 for reasons nothing in the game can see.
*>
fn void a_compaction_moves_the_column_under_the_survivors() @test
{
	@with_gpu_js(; three::JsRuntime* run)
	{
		String value = @value(run, `
			const scene = new three.Scene();
			const Critter = three.track(class Critter {
				constructor(x) { this.position[0] = x; this.tag = x; }
			}, { columns: { position: 3 }, capacity: 8 });

			const all = [10, 20, 30, 40].map(x => Critter.spawn(x));
			all[1].remove();
			all[2].remove();

			// Immediate: gone from of() and from the count, still in the list.
			const beforeCompact = [Critter.count, Critter.column('position').length / 3];
			const removed = Critter.compact();

			return [
				beforeCompact, removed, Critter.count,
				Array.from(Critter.column('position')).filter((_, i) => i % 3 === 0),
				[all[0].position[0], all[3].position[0]],
				[all[0].tag, all[3].tag],
			];
		`, "the compaction script ran");

		test::@check(value == "[[2,4],2,2,[10,40],[10,40],[10,40]]",
			"the floats move down and the survivors keep their own; got %s", value);
	};
}

<*
 An instance is found from a CHILD mesh and from its trigger volume.

 The three things that hand a script an object hand it different ones: a raycast
 and a query answer with the leaf mesh that was hit, `three.onTrigger` answers
 with the volume, and a script holding the thing it spawned has the root. An
 assembled character is a Group of eleven meshes, so a lookup keyed only on the
 root cannot answer a raycast at all — which is why `of` walks up the parents.

 A pickup keyed only by the drawn mesh cannot be collected, and one keyed only by
 the volume cannot be spun into. Both failures look like the pickup not working
 rather than like a lookup missing a key.
*>
fn void an_instance_is_found_from_a_child_and_from_its_volume() @test
{
	@with_gpu_js(; three::JsRuntime* run)
	{
		String value = @value(run, `
			const scene = new three.Scene();
			const Fruit = three.track(class Fruit {
				constructor() {
					this.object = new three.Group();
					this.skin = new three.Mesh(new three.SphereGeometry(0.5, 8, 6));
					this.object.add(this.skin);
					this.object.position.set(2, 1, 0);
				}
			}, { collides: false, trigger: { shape: 'sphere', radius: 0.9 } });

			const Crate = three.track(class Crate {
				constructor() { this.object = new three.Mesh(new three.BoxGeometry(1, 1, 1)); }
			});

			const f = Fruit.spawn();
			const c = Crate.spawn();
			const stranger = new three.Mesh(new three.BoxGeometry(1, 1, 1));
			scene.add(stranger);

			return [
				Fruit.of(f.object) === f,
				Fruit.of(f.skin) === f,
				Fruit.of(f.volume) === f,
				Fruit.of(c.object),
				three.instanceOf(f.skin) === f,
				three.instanceOf(c.object) === c,
				three.instanceOf(stranger),
				f.volume.visible,
				f.volume.scale.x,
				three.physics.count,
			];
		`, "the lookup script ran");

		// Every door reaches the same instance, another class's object is not
		// this one's, a stranger is null, and the volume is a world radius —
		// 0.9 across a unit sphere of 0.5 — rather than a scale factor.
		test::@check(value == "[true,true,true,null,true,true,null,false,1.8,1]",
			"every door reaches the instance and the volume is reach, not geometry; got %s", value);
	};
}

// ============================================================================
// Rules
// ============================================================================

<*
 A rule fires on a trigger, subject first, and both directions fire.

 The argument order is the whole reason a rule hangs off a class rather than
 being `three.on(a, verb, b, fn)`: the rule lives on `Fruit`, so the handler is
 handed `(fruit, player)` in that order and never has to ask which is which. A
 dispatch that passed them the other way round would still "work" for a symmetric
 rule and silently corrupt every asymmetric one.

 The script's own `three.onTrigger` has to keep firing beside it. entity.js owns
 the host slot now, and a script that has never heard of rules must not find its
 handler quietly replaced — which is the failure `systems.js` was built to avoid
 one layer up, repeated here.
*>
fn void a_trigger_reaches_a_rule_subject_first_and_the_script_handler_too() @test
{
	@with_gpu_js(; three::JsRuntime* run)
	{
		String value = @after_frames(run, `
			const scene = new three.Scene();
			const floor = new three.Mesh(new three.BoxGeometry(30, 1, 30));
			scene.add(floor);
			three.physics.add(floor, { shape: 'box', mass: 0 });

			globalThis.Fruit = three.track(class Fruit {
				constructor(x) {
					this.object = new three.Mesh(new three.BoxGeometry(1, 1, 1));
					this.object.position.set(x, 1.2, 0);
					this.order = null;
				}
			}, { collides: false, trigger: { shape: 'sphere', radius: 1.2 } });

			globalThis.Player = three.track(class Player {
				constructor() {
					this.object = new three.Mesh(new three.BoxGeometry(1, 1, 1));
					this.object.position.set(0, 1.2, 0);
					this.fruit = 0;
					this.sawFruit = 0;
				}
			}, { body: { shape: 'box', mass: 0, kinematic: true } });

			globalThis.p = Player.spawn();
			globalThis.f = Fruit.spawn(0.3);

			Fruit.on('enter', Player, (fruit, who) => {
				fruit.order = [fruit === f, who === p];
				who.fruit++;
			});
			// The other direction is a rule on the other class, and both fire.
			Player.on('enter', Fruit, (who, fruit) => { who.sawFruit++; });

			globalThis.raw = 0;
			three.onTrigger(e => { if (e.type === 'enter') raw++; });
		`, 6, "return [f.order, p.fruit > 0, p.sawFruit > 0, raw > 0];", "the trigger script ran");

		test::@check(value == "[[true,true],true,true,true]",
			"the rule is handed (subject, other), both directions fire, and the script handler survives; got %s", value);
	};
}

<*
 A rule replaces by name, and a rule that throws is contained.

 Replacement is what makes a hot reload survivable: §8 re-evaluates `main.js` on
 a file change, and a rules table that appended would end up with two of every
 rule after the first save. The symptom is enemies dealing exactly twice damage,
 which reads as a balance problem rather than as a bug.

 Containment is `systems.js`'s contract rather than `three.onTrigger`'s. A
 handler bound through `onTrigger` is stopped for good when it throws, and that
 is right for a script's ONE handler; a rules table has many, and one bad rule
 taking the other nine with it is the failure this exists to prevent.
*>
fn void a_rule_replaces_by_name_and_a_throwing_rule_is_contained() @test
{
	@with_gpu_js(; three::JsRuntime* run)
	{
		String value = @value(run, `
			const scene = new three.Scene();
			const Critter = three.track(class Critter {
				constructor() { this.object = new three.Mesh(new three.BoxGeometry(1, 1, 1)); this.hit = 0; }
			});
			const Player = three.track(class Player {
				constructor() { this.object = new three.Mesh(new three.BoxGeometry(1, 1, 1)); }
			});
			const c = Critter.spawn();
			const p = Player.spawn();

			// Registering the same rule twice is one rule, not two.
			Critter.on('hit', Player, (x) => { x.hit += 1; }, { name: 'damage' });
			Critter.on('hit', Player, (x) => { x.hit += 1; }, { name: 'damage' });
			three.emit(c, 'hit', p);
			const once = c.hit;

			// A rule that throws does not take the ones after it with it.
			Critter.on('hit', Player, () => { throw new Error('bad rule'); }, { name: 'bad', order: -1 });
			Critter.on('hit', Player, (x) => { x.hit += 10; }, { name: 'after', order: 1 });
			three.emit(c, 'hit', p);

			return [once, c.hit, three.rules().filter(r => r.name === 'damage').length, three.rules().length];
		`, "the rules script ran");

		test::@check(value == "[1,12,1,3]",
			"a duplicate name replaces and a throwing rule is contained; got %s", value);
	};
}

<*
 `near` reads the COLUMN, not the node — and it is the event physics never
 raises.

 `three.moveAndSlide` produces no contact, so a player moved by it either carries
 a phantom kinematic capsule purely to trip triggers, or the game writes the
 distance test by hand; `examples/wumpa_run.js` does both. `{ within }` is that
 loop, once, in the engine.

 Reading the column rather than the node is what makes it correct for a steered
 crowd: the column is where the truth is and the node is a frame behind it until
 the draw system runs. So the test moves an entity through the column ONLY —
 `away.position[0] = 0.2`, with the mesh never touched — and the rule has to
 notice.
*>
fn void a_near_rule_reads_the_column_rather_than_the_node() @test
{
	@with_gpu_js(; three::JsRuntime* run)
	{
		String value = @after_frames(run, `
			const scene = new three.Scene();
			globalThis.Critter = three.track(class Critter {
				constructor(x) {
					this.position[0] = x;
					this.object = new three.Mesh(new three.BoxGeometry(1, 1, 1));
					scene.add(this.object);
					this.touched = 0;
				}
			}, { columns: { position: 3 }, capacity: 8 });

			globalThis.Player = three.track(class Player {
				constructor() {
					this.object = new three.Mesh(new three.BoxGeometry(1, 1, 1));
					this.object.position.set(0, 0, 0);
					this.hurt = 0;
				}
			});

			globalThis.p = Player.spawn();
			globalThis.close = Critter.spawn(0.5);
			globalThis.mid = Critter.spawn(1.8);
			globalThis.away = Critter.spawn(9);

			Critter.on('near', Player, (c, who) => { c.touched++; who.hurt++; }, { within: 1.0 });

			globalThis.moved = false;
			three.systems.add('probe', () => {
				if (moved) return;
				moved = true;
				// The COLUMN only. The mesh stays at the origin it was built at.
				away.position[0] = 0.2;
			}, { order: 1e7 });
		`, 4, "return [close.touched > 0, mid.touched, away.touched > 0, away.object.position.x, p.hurt > 1];",
			"the near script ran");

		test::@check(value == "[true,0,true,0,true]",
			"near fires inside the radius, off it does not, and it follows the column; got %s", value);
	};
}

<*
 An engine event waits for the drain; `three.emit` does not.

 A trigger fires from inside the solver, and a handler that deletes a body there
 is a hazard the game cannot see — so engine events are queued and delivered by
 one system named `rules`, which is also what puts their cost in
 `three.systems.report()`. The price is one frame of latency, and this is the
 test that says so out loud rather than leaving it to be discovered.

 `three.emit` is the game raising its own event from a place the game chose, so
 it dispatches at once. The two halves reaching the same table is the point: a
 rule cannot tell whether a solver or a keypress raised it.
*>
fn void an_engine_event_waits_for_the_drain_and_emit_does_not() @test
{
	@with_gpu_js(; three::JsRuntime* run)
	{
		String value = @value(run, `
			const scene = new three.Scene();
			const Door = three.track(class Door {
				constructor() { this.object = new three.Mesh(new three.BoxGeometry(1, 2, 1)); this.open = false; }
			});
			const Player = three.track(class Player {
				constructor() { this.object = new three.Mesh(new three.BoxGeometry(1, 1, 1)); this.keys = 1; }
			});
			const d = Door.spawn();
			const p = Player.spawn();

			Door.on('use', Player, (door, who) => {
				if (who.keys > 0) { who.keys--; door.open = true; }
			});

			// The whole of a locked door: one class, one rule, nothing else.
			const before = d.open;
			three.emit(p, 'use', d);
			const after = d.open;
			three.emit(p, 'use', d);

			return [before, after, p.keys, three.systems.report().some(s => s.name === 'rules')];
		`, "the door script ran");

		test::@check(value == "[false,true,0,true]",
			"emit dispatches at once and the drain system is registered; got %s", value);
	};
}

<*
 Removing from inside `for (const c of Class)` is safe, and removal is immediate.

 This is the opposite half of the Cast's index rule, and it is deliberate. A
 removal that spliced the live list on the spot would move the iterator under a
 loop that is removing things — and the loop that removes things is exactly a TNT
 taking its neighbours out from inside `for (const c of Crate)`.

 So the LIST waits for the frame boundary and everything a player can SEE does
 not: the node leaves the scene, the body leaves the solver and `of()` answers
 null before `remove` returns. A crate you walked through the ghost of would be
 the bug here.

 What the iteration guarantees is that it runs to the end and yields no dead
 entity — a crate removed at step 1 is not visited at step 3. What it does NOT
 promise is a snapshot: `Class.all()` is the copy for a caller who wants one.
*>
fn void a_removal_is_immediate_and_iteration_survives_it() @test
{
	@with_gpu_js(; three::JsRuntime* run)
	{
		String value = @value(run, `
			const scene = new three.Scene();
			const Crate = three.track(class Crate {
				constructor(i) {
					this.i = i;
					this.object = new three.Mesh(new three.BoxGeometry(1, 1, 1));
					this.object.position.set(i * 2, 1, 0);
				}
				onRemove() { globalThis.removals = (globalThis.removals || 0) + 1; }
			}, { body: { shape: 'box', mass: 0 } });

			for (let i = 0; i < 5; i++) Crate.spawn(i);
			const bodiesBefore = three.physics.count;

			// The TNT loop: removing its neighbours from inside the iteration.
			const seen = [];
			for (const c of Crate) {
				seen.push(c.i);
				if (c.i === 1) for (const other of Crate.all()) if (other.i > 2) other.remove();
			}

			const gone = Crate.all().filter(c => c.i > 2);
			return [
				seen, Crate.count, gone.length,
				bodiesBefore - three.physics.count,
				scene.getObjectByName('Crate#4'),
				globalThis.removals,
			];
		`, "the removal script ran");

		// The loop ran to the end without disturbance and did NOT visit the two
		// it had just removed — a removal is visible to the iteration at once,
		// the same as it is to everything else. Both bodies left the solver on
		// the spot, the node left the scene, and onRemove ran twice.
		test::@check(value == "[[0,1,2],3,0,2,null,2]",
			"a removal is immediate and the iteration survives it; got %s", value);
	};
}

<*
 A `three.Entity` subclass registers ITSELF, from its own statics.

 There is no `three.track` call beside the declaration and nothing to capture,
 which is the whole point of the form: a class declaration cannot run anything,
 so registration is deferred to the first use — `spawn`, `on`, `of`, iteration —
 and reads `static capacity`, `static columns`, `static parent` and the rest off
 the class.

 The failure this guards against is a lazy registration that never happens. A
 class whose first use is `Critter.on(...)` rather than `Critter.spawn(...)` must
 register just the same, or the rule attaches to nothing and the symptom is an
 enemy that never reacts.
*>
fn void an_entity_subclass_registers_itself_from_its_statics() @test
{
	@with_gpu_js(; three::JsRuntime* run)
	{
		String value = @value(run, `
			const scene = new three.Scene();
			const group = new three.Group();
			scene.add(group);

			class Critter extends three.Entity {
				static capacity = 8;
				static parent = group;
				static columns = { position: 3, motion: 3 };
				constructor(x, hp) {
					super();
					this.hp = hp;
					this.position[0] = x;
					this.object = new three.Mesh(new three.BoxGeometry(1, 1, 1));
				}
			}

			// A class whose FIRST use is a rule, not a spawn.
			class Player extends three.Entity {
				constructor() { super(); this.object = new three.Mesh(new three.BoxGeometry(1, 1, 1)); this.hits = 0; }
			}
			Player.on('hit', Critter, (who) => { who.hits++; });

			const a = Critter.spawn(1, 3);
			const b = Critter.spawn(2, 5);
			const p = Player.spawn();
			three.emit(p, 'hit', a);

			b.remove();
			Critter.compact();

			return [
				Critter.count, Player.count, Critter.trackName,
				Array.from(Critter.column('position')),
				Critter.of(a.object) === a,
				three.instanceOf(p.object) === p,
				a.object.parent === group,
				Critter.free, p.hits,
			];
		`, "the entity script ran");

		test::@check(value == "[1,1,\"Critter\",[1,0,0],true,true,true,7,1]",
			"a subclass registers from its statics, on a rule as readily as on a spawn; got %s", value);
	};
}

<*
 `super()` is where a bare `new` is refused, and that is why it catches the case
 nothing else can.

 A class that declares columns is caught anyway — the getter has no slot to
 resolve and says so. A class with NO columns has nothing to trip over, so an
 untracked instance would sail through with no node in the scene, no body in the
 solver and no place in the live list, and the first sign of it would be a thing
 that does not appear.

 This is what the base class buys over `three.track(class ...)`: the check lives
 in the constructor rather than in a Proxy, so there is no answer a caller has to
 remember to capture for it to work.
*>
fn void the_base_constructor_refuses_a_bare_new_even_with_no_columns() @test
{
	@with_gpu_js(; three::JsRuntime* run)
	{
		String value = @value(run, `
			const scene = new three.Scene();

			class WithColumns extends three.Entity {
				static capacity = 4;
				static columns = { position: 3 };
				constructor() { super(); this.object = new three.Mesh(new three.BoxGeometry(1, 1, 1)); }
			}
			class Bare extends three.Entity {
				constructor() { super(); this.object = new three.Mesh(new three.BoxGeometry(1, 1, 1)); }
			}
			Bare.spawn();

			let columned = null, bare = null, base = null;
			try { new WithColumns(); } catch (e) { columned = e.message.slice(0, 9); }
			try { new Bare(); } catch (e) { bare = e.message.slice(0, 9); }
			try { three.Entity.spawn(); } catch (e) { base = e.message.slice(0, 24); }

			return [columned, bare, base, Bare.count, scene.children.length];
		`, "the refusal script ran");

		// Both forms refuse, and three.Entity itself is not spawnable — it is
		// the base to extend, and the entities belong to the subclass.
		test::@check(value == "[\"new WithC\",\"new Bare(\",\"three.Entity.spawn is no\",1,1]",
			"the base constructor refuses a bare new, columns or not; got %s", value);
	};
}

<*
 The trigger volume is a SIBLING, so it has to be carried — and only a class
 that declares one pays for the carrying.

 A body-backed node has to be a direct child of the scene, because the solver
 works in world space and a parent transform would fight it. So a pickup that
 draws at one radius and is collected at another is two nodes side by side rather
 than one inside the other, and nothing carries the second. A volume left behind
 is a pickup collected where the fruit used to be: no error, no drawn clue, and a
 bug reported as the trigger being unreliable.

 `<Class>.follow` is what carries it, registered only for a class with a trigger
 — asserted here too, because a system running over an empty list is a cost every
 class would pay for a feature most do not use.
*>
fn void a_trigger_volume_follows_the_object_it_belongs_to() @test
{
	@with_gpu_js(; three::JsRuntime* run)
	{
		String value = @after_frames(run, `
			new three.Scene();
			globalThis.Fruit = three.track(class Fruit {
				constructor() {
					this.object = new three.Mesh(new three.SphereGeometry(0.5, 8, 6));
					this.object.position.set(0, 1, 0);
				}
			}, { trigger: { shape: 'sphere', radius: 0.9, offset: [0, 0.25, 0] } });

			globalThis.Plain = three.track(class Plain {
				constructor() { this.object = new three.Mesh(new three.BoxGeometry(1, 1, 1)); }
			});

			globalThis.f = Fruit.spawn();
			globalThis.placed = [f.volume.position.x, f.volume.position.y];
			f.object.position.set(5, 3, -2);
		`, 2, `
			const names = three.systems.list().map(s => s.name).sort();
			return [
				placed,
				[f.volume.position.x, f.volume.position.y, f.volume.position.z],
				names.join(','),
			];
		`, "the follow script ran");

		// Placed at the spawn with its offset, carried to wherever the drawn
		// object went with the offset still on it, and only the class with a
		// trigger registered a follow.
		test::@check(value == "[[0,1.25],[5,3.25,-2],\"Fruit.compact,Fruit.follow,Plain.compact\"]",
			"the volume follows its object, and only a trigger pays for it; got %s", value);
	};
}

<*
 `collides: false` reaches every mesh in the subtree and no Group.

 `object.collides` says what one piece of GEOMETRY is and is deliberately not
 inherited, so writing it on the root would leave a character made of eight boxes
 colliding with its own chest — which is the hide/show dance
 `examples/wumpa_run.js` spent a `noCollide` traverse on before there was a flag.
 Setting it before the add is what makes it one crossing per mesh at
 `_materialize` rather than an index rebuild apiece.
*>
fn void collides_false_reaches_every_mesh_under_the_root() @test
{
	@with_gpu_js(; three::JsRuntime* run)
	{
		String value = @value(run, `
			new three.Scene();
			class Critter extends three.Entity {
				static collides = false;
				constructor() {
					super();
					this.object = new three.Group();
					this.object.add(new three.Mesh(new three.BoxGeometry(1, 1, 1)));
					const limb = new three.Group();
					this.object.add(limb);
					limb.add(new three.Mesh(new three.BoxGeometry(1, 1, 1)));
				}
			}
			const c = Critter.spawn();
			const seen = [];
			c.object.traverse(o => seen.push(o.collides));
			// A sphere over the whole thing finds nothing, because nothing in it
			// is collision geometry any more.
			return [seen, three.query.sphere([0, 0, 0], 4).length];
		`, "the collides script ran");

		// Both Groups answer true because a Group is not geometry and nothing
		// was written to them; both meshes are off; the spatial index agrees.
		test::@check(value == "[[true,false,true,false],0]",
			"collides reaches the meshes and not the Groups; got %s", value);
	};
}

<*
 The refusals, and every one of them is a bug that would otherwise be silent.

 A duplicate name would leave the first class's nodes and bodies with nothing to
 name them. A `parent` beside a body would put a body-backed node under a
 transform the solver knows nothing about, which works until somebody moves the
 group. A `this.object` that is not an Object3D would fail later, at the add,
 with a message about the add. And a column asked for without a capacity would
 have to grow, which cannot be done under live windows — so it is refused where
 the capacity is written rather than where the growth would have happened.
*>
fn void a_tracked_class_refuses_what_would_go_wrong_quietly() @test
{
	@with_gpu_js(; three::JsRuntime* run)
	{
		String value = @value(run, `
			new three.Scene();
			const said = f => { try { f(); return 'no throw'; } catch (e) { return e.message; } };
			const box = () => new three.Mesh(new three.BoxGeometry(1, 1, 1));

			class Crate { constructor() { this.object = box(); } }
			three.track(Crate);
			class Crate2 { constructor() { this.object = box(); } }
			const duplicate = said(() => three.track(Crate2, { name: 'Crate' }));

			class Parented { constructor() { this.object = box(); } }
			const parented = said(() => three.track(Parented, {
				body: { shape: 'box' }, parent: new three.Group(),
			}));

			class Wrong { constructor() { this.object = { nope: true }; } }
			three.track(Wrong);
			const notAnObject = said(() => Wrong.spawn());

			class NoCap { }
			const noCapacity = said(() => three.track(NoCap, { columns: { position: 3 } }));

			class Full extends three.Entity {
				static capacity = 1;
				static columns = { position: 3 };
				constructor() { super(); this.object = box(); }
			}
			Full.spawn();
			const overflow = said(() => Full.spawn());

			return [
				duplicate.includes("already a tracked class called 'Crate'") && duplicate.includes('dispose()'),
				parented.includes('world space'),
				notAnObject.includes('this.object must be a Mesh or a Group'),
				noCapacity.includes('capacity') && noCapacity.includes('cannot grow'),
				overflow.includes('is full at 1'),
			];
		`, "the refusal script ran");

		test::@check(value == "[true,true,true,true,true]",
			"every refusal names the call and says what to do; got %s", value);
	};
}

<*
 `dispose` takes the class's systems, its entities, its rules and its NAME.

 The systems half is `test/systems_test.c3`'s argument: a level teardown that
 left the compaction pass behind leaves the registry calling into something
 nothing else references. The name half is this file's own — a duplicate is
 refused, so a script that could not give the name back would be a script that
 cannot rebuild its own level. And the rules go with it, because a rule whose
 subject class no longer exists can never fire and would sit in `three.rules()`
 forever looking like it might.
*>
fn void disposing_a_class_gives_back_its_systems_rules_and_name() @test
{
	@with_gpu_js(; three::JsRuntime* run)
	{
		String value = @value(run, `
			const scene = new three.Scene();
			const before = three.systems.length;

			const Fruit = three.track(class Fruit {
				constructor(i) {
					this.object = new three.Mesh(new three.SphereGeometry(0.5, 8, 6));
					this.object.position.set(i, 1, 0);
				}
			}, { trigger: { shape: 'sphere', radius: 0.9 } });

			for (let i = 0; i < 3; i++) Fruit.spawn(i);
			Fruit.on('enter', '*', () => {});
			const registered = three.systems.list().map(s => s.name).filter(n => n.startsWith('Fruit.')).sort();
			const bodies = three.physics.count;
			const rules = three.rules().length;

			Fruit.dispose();
			const again = three.track(class Fruit {
				constructor() { this.object = new three.Mesh(new three.BoxGeometry(1, 1, 1)); }
			});

			let spawned = 'no throw';
			try { Fruit.spawn(0); } catch (e) { spawned = e.message; }

			return [
				before, registered.join(','), bodies, rules,
				three.physics.count, scene.children.length, three.rules().length,
				three.systems.list().map(s => s.name).join(','),
				again.trackName, again.count,
				spawned.includes('has been tracked and then disposed'),
			];
		`, "the dispose script ran");

		// Nothing registered to start with; a class with a trigger adds two
		// systems and three volumes' bodies; dispose takes the entities, the
		// bodies, the nodes, the rules and the systems; the name comes back; and
		// the disposed class refuses to spawn what nothing would compact.
		test::@check(value == "[0,\"Fruit.compact,Fruit.follow\",3,1,0,0,0,\"rules,Fruit.compact\",\"Fruit\",0,true]",
			"a class's systems, entities, rules and name leave with it; got %s", value);
	};
}

<*
 A removal does not move anybody until the frame ends, and the boundary is a
 registered system rather than a call the script makes.

 The instance is the durable handle — that is the difference from a slot, and it
 is why there is no generation to carry. A system holding `c` across another
 entity's removal is still holding the same critter afterwards, because `c` never
 meant "slot 3"; what moves at the boundary is the float triple under it, and the
 getter reads whichever slot the instance is in now.

 The failure this guards is a compaction that ran on the spot: the survivors'
 columns would shift under any system mid-frame, and the symptom is the wrong
 entity taking damage rather than anything that looks like an indexing error.
*>
fn void a_removal_takes_effect_at_the_end_of_the_frame() @test
{
	@with_gpu_js(; three::JsRuntime* run)
	{
		String value = @after_frames(run, `
			new three.Scene();
			globalThis.log = [];
			class Critter extends three.Entity {
				static capacity = 8;
				static columns = { mark: 1 };
				constructor(i) { super(); this.mark[0] = i + 1; this.i = i; }
			}
			globalThis.Critter = Critter;
			globalThis.all = [];
			for (let i = 0; i < 5; i++) all.push(Critter.spawn(i));

			let frames = 0;
			Critter.system('watch', () => {
				frames++;
				if (frames === 1) {
					all[1].remove();
					// Same frame, after the removal: the slots have not moved.
					log.push([Critter.column('mark').length, Critter.count, all[3].mark[0], Critter.of(all[1].object)]);
				}
				if (frames === 2) {
					// After the boundary the array is short and every survivor
					// still reads its own number.
					log.push([Critter.column('mark').length, Critter.count, all[3].mark[0], [...Critter].map(c => c.mark[0])]);
				}
			}, { order: 0 });
		`, 4, `return log;`, "the deferred-removal script ran");

		// In the frame of the removal: five slots, four alive, the fourth still
		// reading its own mark. After the boundary: four slots, the marks intact
		// and in spawn order, with the removed one's gone.
		test::@check(value == "[[5,4,4,null],[4,4,4,[1,3,4,5]]]",
			"the slot lingers for the frame and the instance never moves; got %s", value);
	};
}

<*
 The columns ARE the buffers, through a real sweep and a real draw.

 `a_column_is_a_window_and_the_host_writes_through_it` makes the claim against
 `three.steer`; this makes it against the two that finish a frame —
 `three.moveAndSlideAll`, which needs the `self` handle column so an agent does
 not sweep against its own mesh, and the flush, which sends the whole pack's
 transforms in one crossing.

 If either of these ever needed a copy, the class would have become a marshalling
 step in front of the verbs that exist to remove one.
*>
fn void the_columns_are_what_the_sweep_and_the_flush_take() @test
{
	@with_gpu_js(; three::JsRuntime* run)
	{
		String value = @value(run, `
			const scene = new three.Scene();
			const floor = new three.Mesh(new three.BoxGeometry(60, 1, 60));
			floor.position.y = -0.5;
			scene.add(floor);

			class Critter extends three.Entity {
				static capacity = 6;
				static columns = { position: 3, motion: 3, move: three.moveResult.stride };
				constructor(i) {
					super();
					this.position[0] = i * 4;
					this.position[1] = 0.6;
					this.motion[0] = 0.5;
					this.motion[1] = -0.05;
					this.object = new three.Group();
					const body = new three.Mesh(new three.BoxGeometry(0.6, 0.8, 0.6));
					body.position.y = 0.6;
					this.object.add(body);
					this.object.position.set(i * 4, 0, 0);
				}
			}
			const all = [];
			for (let i = 0; i < 4; i++) all.push(Critter.spawn(i));

			// The live prefix is a subarray of the column, not a copy, and it is
			// cached so reading it inside a frame allocates nothing.
			const view = Critter.column('position');
			const sameMemory = view.buffer === all[0].position.buffer && view.length === Critter.count * 3;
			const cached = Critter.column('position') === view;

			const stepped = three.moveAndSlideAll(view, Critter.column('motion'), {
				radius: 0.4, height: 1.2, step: 0.4, slope: 50, snap: 0.3,
				results: Critter.column('move'), self: Critter.handles,
			});

			// It wrote through the view into the instance's own window.
			const wrote = Math.abs(all[0].position[0] - 0.5) < 0.01;
			let grounded = 0;
			for (const c of Critter) {
				if ((c.move[three.moveResult.flags] | 0) & three.moveResult.GROUNDED) grounded++;
			}

			// And drawing them is one more crossing.
			Critter.pose('position', { lift: -0.6 });
			const flushed = Critter.flush();
			const stale = all[0].object.position.x === 0;
			const synced = Critter.sync();
			const agrees = Math.abs(all[0].object.position.x - all[0].position[0]) < 1e-6;

			return [sameMemory, cached, stepped, wrote, grounded, flushed, stale, synced, agrees];
		`, "the columns script ran");

		// Same memory, cached view, four stepped, the column written through,
		// all four grounded, four flushed in one crossing, the objects stale
		// until sync and in agreement after it.
		test::@check(value == "[true,true,4,true,4,4,true,4,true]",
			"a column is the buffer the sweep and the flush take; got %s", value);
	};
}

<*
 A VOLUME is a second body beside the drawn node, and a solid one shoves.

 `static trigger` was only ever half the shape. A player moved by
 `three.moveAndSlide` has no body at all, so every game that wanted to trip its
 own triggers built the same six lines by hand — an invisible mesh, a scale, a
 name, a `physics.add` with `kinematic: true`, and a line in the pose system to
 carry it — and then had to remember the carry when it moved. `static volume`
 is that, declared once.

 The three things this pins down are the three that were hand-written:

 - it is a KINEMATIC BODY and not a trigger, so `enter` does not fire for it and
   a dynamic body pushed into it is pushed back out;
 - the drawn node may have a PARENT while the volume may not, and `follow` reads
   a world position when it does — a volume that tracked the local position
   would sit at the origin of whatever Group the character hangs from, which is
   the failure that looks like the collider being "offset";
 - `follow` runs BEFORE the proximity pass, not after, so a `near` rule measures
   this frame's volume rather than last frame's.
*>
fn void a_solid_volume_is_a_kinematic_body_that_follows_a_parented_node() @test
{
	@with_gpu_js(; three::JsRuntime* run)
	{
		String value = @after_frames(run, `
			const scene = new three.Scene();
			const rig = new three.Group();
			rig.position.set(10, 0, 0);
			scene.add(rig);

			globalThis.Hero = class Hero extends three.Entity {
				static parent = rig;
				static collides = false;
				static volume = { shape: 'capsule', radius: 0.42, height: 1.75, offset: [0, 0.875, 0] };
				constructor() {
					super();
					this.object = new three.Mesh(new three.BoxGeometry(0.8, 1.75, 0.8));
					this.object.position.set(1, 0, 2);
				}
			};

			// A trigger on something else, to prove the solid one is not one.
			globalThis.Coin = class Coin extends three.Entity {
				static collides = false;
				static trigger = { shape: 'sphere', radius: 0.9 };
				constructor(x, z) {
					super();
					this.object = new three.Mesh(new three.SphereGeometry(0.3));
					this.object.position.set(x, 0.9, z);
				}
			};

			globalThis.hero = Hero.spawn();
			Coin.spawn(11.2, 2);
			globalThis.picked = 0;
			Coin.on('enter', Hero, (c, h) => { c.remove(); picked++; });

			// Moved through the drawn node only, in the rig's LOCAL frame.
			globalThis.moved = false;
			three.systems.add('probe', () => {
				if (moved) return;
				moved = true;
				hero.object.position.set(4, 0, 2);
			}, { order: 1e7 });
		`, 6, `
			const list = three.systems.list();
			const follow = list.findIndex(s => s.name === 'Hero.follow');
			return [
				picked,
				hero.volume.visible,
				[hero.volume.position.x, hero.volume.position.y, hero.volume.position.z],
				follow >= 0 && follow < list.findIndex(s => s.name === 'Coin.follow'),
			];`, "the volume script ran");

		// One coin collected through the solid capsule, the volume invisible and
		// carried to the WORLD position — rig 10 plus the local 4 — and both
		// follows registered.
		test::@check(value == "[1,false,[14,0.875,2],true]",
			"a volume is an invisible body carried to where its object really is; got %s", value);
	};
}

<*
 `near` measures against the VOLUME when a class has one.

 A character's node sits at its feet and its capsule sits at its middle, and half
 a body height is most of a `within` radius — so a rule tuned against a
 hand-carried capsule would change meaning the moment the capsule became a
 declaration. This is the test that says it did not.

 The subject is one unit above the ground with no volume of its own; the other
 has a capsule lifted by `HEIGHT / 2`. Measured against the node the two are a
 unit apart and the rule is silent; measured against the volume they are level
 and it fires.
*>
fn void a_near_rule_measures_against_the_volume_rather_than_the_node() @test
{
	@with_gpu_js(; three::JsRuntime* run)
	{
		String value = @after_frames(run, `
			const scene = new three.Scene();

			globalThis.Hero = class Hero extends three.Entity {
				static collides = false;
				static volume = { shape: 'capsule', radius: 0.4, height: 1.8, offset: [0, 0.9, 0] };
				constructor() {
					super();
					this.object = new three.Mesh(new three.BoxGeometry(0.8, 1.8, 0.8));
					// Feet at the origin; the capsule's middle is at y = 0.9.
					this.object.position.set(0, 0, 0);
					this.hit = 0;
				}
			};

			globalThis.Wasp = class Wasp extends three.Entity {
				static collides = false;
				constructor(y) {
					super();
					this.object = new three.Mesh(new three.SphereGeometry(0.2));
					this.object.position.set(0, y, 0);
					this.stung = 0;
				}
			};

			globalThis.level = Wasp.spawn(0.9);   // level with the capsule's middle
			globalThis.low = Wasp.spawn(0.0);     // level with the feet
			Hero.spawn();

			Wasp.on('near', Hero, (w, h) => { w.stung++; h.hit++; }, { within: 0.5 });
		`, 5, "return [level.stung > 0, low.stung];", "the near-volume script ran");

		// The one level with the capsule is reached; the one at the node's own
		// height, 0.9 away, is not.
		test::@check(value == "[true,0]",
			"near measures against the volume, so a tuned radius keeps its meaning; got %s", value);
	};
}

<*
 The refusals a volume brings.

 A trigger IS a volume with the flag on, so declaring both is a script that
 believes it is getting two nodes and is getting one. A capsule without a height
 is a capsule of height zero, which collides with nothing and reports nothing —
 the worst kind of silence, because everything else about it looks built. And a
 shape a volume does not come in has to say which three it does, at the
 declaration, rather than at the first frame nothing overlaps.
*>
fn void a_volume_refuses_what_cannot_be_built() @test
{
	@with_gpu_js(; three::JsRuntime* run)
	{
		String value = @value(run, `
			new three.Scene();
			const said = [];
			const refuse = (fn) => { try { fn(); return 'no refusal'; } catch (e) { said.push(e.message); return true; } };

			const both = refuse(() => {
				class Both extends three.Entity {
					static volume = { shape: 'sphere', radius: 1 };
					static trigger = { shape: 'sphere', radius: 1 };
					constructor() { super(); }
				}
				Both.spawn();
			});

			const noHeight = refuse(() => {
				class Tall extends three.Entity {
					static volume = { shape: 'capsule', radius: 0.4 };
					constructor() { super(); }
				}
				Tall.spawn();
			});

			const badShape = refuse(() => {
				class Odd extends three.Entity {
					static volume = { shape: 'torus', radius: 0.4 };
					constructor() { super(); }
				}
				Odd.spawn();
			});

			return [both, noHeight, badShape,
				said[0].includes('same node'), said[1].includes('height'), said[2].includes('capsule')];
		`, "the refusal script ran");

		test::@check(value == "[true,true,true,true,true,true]",
			"a volume says what is wrong at the declaration; got %s", value);
	};
}
