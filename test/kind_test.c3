<*
 Kinds and assemble — `notes.md` §22.

	`c3c test --trust=full --test-noleak --test-filter three_tests::kind`

 **Both of these are JavaScript over a C3 world, and the failures they can have
 are the quiet kind.** A kind owns three things that are only visible from
 outside — a node in the scene, a body in the solver, and a record in a map —
 and the whole point of `remove` is that it takes all three away at once. Any
 one of them left behind is a bug nothing throws about: a body with no mesh
 shoves the player out of an empty space, a mesh with no body draws a crate that
 was broken, and a record left in the map answers `of()` with a thing that is
 not there any more.

 `assemble`'s failures are the same shape one layer up. A mirrored pair in the
 wrong order poses the wrong leg; a `pivot` that is not a Group swings the mesh
 about its own centre and reads as a limb detaching; and a shape that allocated
 a geometry per part is a scene of a hundred draw calls where a hundred copies
 of four shapes were asked for. None of those throw either.
*>
module three_tests::kind;

import three;
import vk;
import qjs;
import std::core::test;
import std::io;

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
// Kinds
// ============================================================================

<*
 A spawn puts a node in the scene and a REAL body in the solver.

 Counting bodies would pass for a `physicsAdd` that filed a handle and did
 nothing, so the check is that the crate falls: a dynamic box spawned in the air
 lands on a static floor, which is a claim about the solver rather than about
 the bookkeeping in front of it.

 The node half is asked of the scene rather than of the record — the record is
 what is being tested, and `getObjectByName` walks the tree the host was told
 about.
*>
fn void a_spawn_places_a_node_and_a_body_that_the_solver_owns() @test
{
	@with_gpu_js(; three::JsRuntime* run)
	{
		String built = @value(run, `
			const scene = new three.Scene();
			const floor = new three.Mesh(new three.BoxGeometry(20, 1, 20));
			floor.position.y = -0.5;
			scene.add(floor);
			three.physics.add(floor, { shape: 'box', mass: 0 });

			globalThis.crate = three.kind('crate', {
				build: () => { const m = new three.Mesh(new three.BoxGeometry(1, 1, 1)); m.scale.set(1.2, 1.2, 1.2); return m; },
				body: { shape: 'box', mass: 5, friction: 0.7 },
				data: p => ({ variant: p.k }),
			});
			globalThis.c = crate.spawn([0, 6, 0], { k: 'tnt', yaw: 0.5 });
			return [
				three.physics.count,
				scene.getObjectByName('crate#0') === c.object,
				c.variant, c.kind === crate, c.volume,
				Math.abs(c.object.rotation.y - 0.5) < 1e-9,
				crate.count, crate.name,
			];
		`, "the spawn script ran");

		// A floor and a crate, the node in the scene under the kind's own name,
		// the record carrying its data and the three reserved fields, and the
		// yaw written as a heading.
		test::@check(built == "[2,true,\"tnt\",true,null,true,1,\"crate\"]",
			"a spawn places a node, a body and a record; got %s", built);

		// Two seconds of frames at the host's fixed 60 Hz — the same fixture
		// `test/physics_test.c3` drops a ball with.
		for (int i = 1; i <= 120; i++) run.tick((double)i * (1000.0 / 60.0));

		String landed = @value(run, "return [c.object.position.y < 1.5, c.object.position.y > 0];",
			"the reading script ran");
		test::@check(landed == "[true,true]",
			"and the body is the solver's, not a handle in a list; got %s", landed);
	};
}

<*
 The record is found from the drawn object AND from its trigger volume.

 The two things that hand a script an object hand it different ones: a query and
 a raycast answer with what is DRAWN, and `three.onTrigger` answers with the
 VOLUME. A pickup keyed only by the drawn mesh cannot be collected and a pickup
 keyed only by the volume cannot be spun into, and both failures look like the
 pickup not working rather than like a lookup missing a key.

 `three.kindOf` is the same question with no kind in hand, which is what a rule
 keyed on "what are these two things" opens with.
*>
fn void a_record_is_found_from_its_object_and_from_its_volume() @test
{
	@with_gpu_js(; three::JsRuntime* run)
	{
		String value = @value(run, `
			const scene = new three.Scene();
			const fruit = three.kind('fruit', {
				build: () => new three.Mesh(new three.SphereGeometry(0.5, 8, 6)),
				collides: false,
				trigger: { shape: 'sphere', radius: 0.9 },
				data: () => ({ bob: 0 }),
			});
			const crate = three.kind('crate', {
				build: () => new three.Mesh(new three.BoxGeometry(1, 1, 1)),
			});
			const f = fruit.spawn([2, 1, 0]);
			const c = crate.spawn([0, 1, 0]);
			const stranger = new three.Mesh(new three.BoxGeometry(1, 1, 1));
			scene.add(stranger);

			return [
				fruit.of(f.object) === f,
				fruit.of(f.volume) === f,
				fruit.of(c.object),
				three.kindOf(f.object) === fruit,
				three.kindOf(f.volume) === fruit,
				three.kindOf(c.object) === crate,
				three.kindOf(stranger),
				f.volume.visible,
				// A world radius, not a scale: 0.9 across a unit sphere of 0.5.
				f.volume.scale.x,
				three.physics.count,
			];
		`, "the lookup script ran");

		// Both doors reach the same record, another kind's object is not this
		// kind's, kindOf answers across both and null for a stranger, the volume
		// is invisible and 1.8 across, and only the volume has a body.
		test::@check(value == "[true,true,null,true,true,true,null,false,1.8,1]",
			"a record is found from either object; got %s", value);
	};
}

<*
 A removal is immediate; only the LIST waits for the frame.

 **This is the decision `notes.md` §22 records, and it is the opposite of the
 Cast's.** A cast is indexed by slot, so closing the gap on the spot would move
 somebody else's index — the bug that looks like the wrong entity taking damage.
 A kind is addressed by an object, and an object does not move, so what has to
 happen at once is the half a player can SEE: a crate broken inside a spin must
 stop colliding and stop drawing on that tick.

 What waits is the live ARRAY, because `for (const c of crate)` removing things
 is exactly the loop a TNT is. So the iteration skips the dead record straight
 away and the array is spliced by `crate.compact` at the frame boundary — which
 is asserted by a later `compact()` having nothing left to do.
*>
fn void a_removal_is_immediate_and_the_list_compacts_at_the_frame() @test
{
	@with_gpu_js(; three::JsRuntime* run)
	{
		String value = @after_frames(run, `
			const scene = new three.Scene();
			globalThis.crate = three.kind('crate', {
				build: () => new three.Mesh(new three.BoxGeometry(1, 1, 1)),
				body: { shape: 'box', mass: 5 },
			});
			globalThis.log = [];
			globalThis.records = [];
			for (let i = 0; i < 3; i++) records.push(crate.spawn([i * 3, 4, 0]));

			const before = three.physics.count;
			const gone = crate.remove(records[1]);
			log.push([
				gone,
				crate.of(records[1].object),
				crate.count,
				[...crate].length,
				[...crate].map(r => r.object.name).join(','),
				before - three.physics.count,
				records[1].object.parent,
				scene.getObjectByName('crate#1'),
				crate.remove(records[1]),
			]);
		`, 2, `
			// The registered system already ran, so there is nothing left for a
			// hand-driven compaction to do.
			log.push([crate.compact(), crate.count, [...crate].length]);
			return log;
		`, "the removal script ran");

		// Removed once and answering false the second time; the record
		// unreachable, the count down, the iteration already skipping it, the
		// body gone, the node out of the scene — all before the call returned.
		// Then the boundary, after which the array itself is short.
		test::@check(
			value == "[[true,null,2,2,\"crate#0,crate#2\",1,null,null,false],[0,2,2]]",
			"a removal is immediate and the list compacts at the frame; got %s", value
		);
	};
}

<*
 The trigger volume is a SIBLING, so it has to be carried.

 A body-backed node has to be a direct child of the scene — the solver works in
 world space and a parent transform would fight it — so a pickup that draws at
 one radius and is collected at another is two nodes side by side rather than
 one inside the other. Nothing carries the second one, and a volume left behind
 is a pickup collected where the fruit used to be: no error, no drawn clue, and
 a bug reported as the trigger being unreliable.

 The `<kind>.follow` system is what carries it, and it is registered only for a
 kind that declares a trigger — which is asserted here as well, because a system
 running over an empty follow list is a cost every kind would pay for a feature
 most do not use.
*>
fn void a_trigger_volume_follows_the_object_it_belongs_to() @test
{
	@with_gpu_js(; three::JsRuntime* run)
	{
		String value = @after_frames(run, `
			new three.Scene();
			globalThis.fruit = three.kind('fruit', {
				build: () => new three.Mesh(new three.SphereGeometry(0.5, 8, 6)),
				trigger: { shape: 'sphere', radius: 0.9, offset: [0, 0.25, 0] },
			});
			globalThis.plain = three.kind('plain', {
				build: () => new three.Mesh(new three.BoxGeometry(1, 1, 1)),
			});
			globalThis.f = fruit.spawn([0, 1, 0]);
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
		// object went with the offset still on it, and only the kind with a
		// trigger registered a follow.
		test::@check(value == "[[0,1.25],[5,3.25,-2],\"fruit.compact,fruit.follow,plain.compact\"]",
			"the volume follows its object; got %s", value);
	};
}

<*
 `collides: false` reaches every mesh in the built subtree and no Group.

 `object.collides` says what one piece of GEOMETRY is and is deliberately not
 inherited, so a kind that wrote it on the root would leave a character made of
 eight boxes colliding with its own chest — which is the hide/show dance
 `examples/wumpa_run.js` spent a `noCollide` traverse on before there was a
 flag. Setting it before the add is what makes it one crossing per mesh at
 `_materialize` rather than an index rebuild apiece.
*>
fn void collides_false_reaches_every_mesh_under_the_root() @test
{
	@with_gpu_js(; three::JsRuntime* run)
	{
		String value = @value(run, `
			new three.Scene();
			const critter = three.kind('critter', {
				collides: false,
				build: () => {
					const g = new three.Group();
					const body = new three.Mesh(new three.BoxGeometry(1, 1, 1));
					g.add(body);
					const limb = new three.Group();
					g.add(limb);
					const foot = new three.Mesh(new three.BoxGeometry(1, 1, 1));
					limb.add(foot);
					return g;
				},
			});
			const c = critter.spawn([0, 0, 0]);
			const seen = [];
			c.object.traverse(o => seen.push(o.collides));
			// A sphere over the whole thing finds nothing, because nothing in it
			// is collision geometry any more.
			return [seen, three.query.sphere([0, 0, 0], 4).length];
		`, "the collides script ran");

		// The root Group and the inner Group answer true because a Group is not
		// geometry and nothing was written to them; both meshes are off; and the
		// spatial index agrees.
		test::@check(value == "[[true,false,true,false],0]",
			"collides reaches the meshes and not the Groups; got %s", value);
	};
}

<*
 The four refusals, and every one of them is a bug that would otherwise be
 silent.

 A duplicate name would leave the first kind's nodes and bodies with nothing to
 name them. A `parent` beside a body would put a body-backed node under a
 transform the solver knows nothing about, which works until somebody moves the
 group. A `data` that answered with an `object` would replace the one thing that
 makes a record findable from what you hit. And a `build` that answered with
 something that is not an Object3D would fail later, at the `add`, with a
 message about the add.
*>
fn void a_kind_refuses_what_would_otherwise_go_wrong_quietly() @test
{
	@with_gpu_js(; three::JsRuntime* run)
	{
		String value = @value(run, `
			new three.Scene();
			const said = f => { try { f(); return 'no throw'; } catch (e) { return e.message; } };
			const box = () => new three.Mesh(new three.BoxGeometry(1, 1, 1));

			three.kind('crate', { build: box });
			const duplicate = said(() => three.kind('crate', { build: box }));
			const parented = said(() => three.kind('parented', {
				build: box, body: { shape: 'box' }, parent: new three.Group(),
			}));
			const reserved = three.kind('reserved', { build: box, data: () => ({ object: 1 }) });
			const clash = said(() => reserved.spawn([0, 0, 0]));
			const wrong = three.kind('wrong', { build: () => ({ nope: true }) });
			const notAnObject = said(() => wrong.spawn([0, 0, 0]));
			const noBuild = said(() => three.kind('noBuild', {}));

			return [
				duplicate.includes("already a kind called 'crate'") && duplicate.includes('dispose()'),
				parented.includes('world space'),
				clash.includes("data(params) answered with a 'object'"),
				notAnObject.includes('build(params) must answer with a Mesh or a Group'),
				noBuild.includes('spec.build must be a function'),
			];
		`, "the refusal script ran");

		test::@check(value == "[true,true,true,true,true]",
			"every refusal names the call and says what to do; got %s", value);
	};
}

<*
 `dispose` takes the kind's systems, its entities and its NAME with it.

 The systems half is `test/systems_test.c3`'s argument for a Cast: a level
 teardown that left the compaction pass behind leaves the registry calling into
 something nothing else references. The name half is this file's own: a kind
 refuses a duplicate, so a script that could not give the name back would be a
 script that cannot rebuild its own level.
*>
fn void disposing_a_kind_gives_back_its_systems_and_its_name() @test
{
	@with_gpu_js(; three::JsRuntime* run)
	{
		String value = @value(run, `
			const scene = new three.Scene();
			const before = three.systems.length;
			const fruit = three.kind('fruit', {
				build: () => new three.Mesh(new three.SphereGeometry(0.5, 8, 6)),
				trigger: { shape: 'sphere', radius: 0.9 },
			});
			for (let i = 0; i < 3; i++) fruit.spawn([i, 1, 0]);
			const registered = three.systems.list().map(s => s.name).filter(n => n.startsWith('fruit.')).sort();
			const bodies = three.physics.count;

			fruit.dispose();
			const again = three.kind('fruit', { build: () => new three.Mesh(new three.BoxGeometry(1, 1, 1)) });

			let spawned = 'no throw';
			try { fruit.spawn([0, 1, 0]); } catch (e) { spawned = e.message; }

			return [
				before, registered.join(','), bodies,
				three.physics.count, scene.children.length,
				three.systems.list().map(s => s.name).join(','),
				again.name, again.count,
				spawned.includes('has been disposed'),
			];
		`, "the dispose script ran");

		// Nothing registered to start with; a kind with a trigger adds two
		// systems and three volumes' bodies; dispose takes the entities, the
		// bodies, the nodes and the systems, the name comes back, and the
		// disposed kind refuses to spawn anything nothing would compact.
		test::@check(value == "[0,\"fruit.compact,fruit.follow\",3,0,0,\"fruit.compact\",\"fruit\",0,true]",
			"a kind's systems, entities and name leave with it; got %s", value);
	};
}

// ============================================================================
// assemble
// ============================================================================

<*
 The parts come back named, the pair comes back in pose order, and the pivot is
 the thing that swings.

 **`[negative, positive]` is `for (const sx of [-1, 1])`'s order and it is a
 compatibility promise**, because every hand-built character in `examples/` was
 written that way and swapping the two is silent: the legs still swing, out of
 phase, which reads as an animation bug rather than as an indexing one.

 The pivot half is checked by rotating and measuring, not by looking at the
 tree: `P.leg[0].rotation.x = swing` has to move the mesh's WORLD position,
 because a part that came back as the mesh instead of the Group would rotate
 about its own centre and stay exactly where it was.
*>
fn void assemble_names_its_parts_and_swings_them_from_their_pivots() @test
{
	@with_gpu_js(; three::JsRuntime* run)
	{
		String value = @value(run, `
			const scene = new three.Scene();
			const mat = new three.MeshLambertMaterial();
			const P = three.assemble({
				spinner: { parts: {
					body: { box: [0.78, 0.82, 0.62], at: [0, 0.86, 0], color: 0xd86a1e },
					leg:  { mirror: 'x', pivot: [0.22, 0.46, 0], box: [0.26, 0.5, 0.3], at: [0, -0.23, 0] },
				} },
				tail: { cylinder: [0.1, 0.2, 0.5], at: [0, 0.5, -0.4] },
			}, { material: mat, collides: false, name: 'guy' });
			scene.add(P.root);

			const round = v => [+v.x.toFixed(3), +v.y.toFixed(3), +v.z.toFixed(3)];
			const before = round(P.leg[0].children[0].getWorldPosition());
			P.leg[0].rotation.x = Math.PI / 2;
			const after = round(P.leg[0].children[0].getWorldPosition());

			const meshes = [];
			P.root.traverse(o => { if (o.geometry) meshes.push(o.collides); });

			return [
				Object.keys(P).join(','),
				P.root.name,
				// The mirrored axis of the PIVOT is what is negated, and the
				// mesh sits at its own 'at' inside each of them.
				[P.leg[0].position.x, P.leg[1].position.x],
				P.leg[0].children[0].position.y,
				before, after,
				// A pivot part is the Group; a plain one is the mesh.
				P.leg[0].children.length === 1 && P.leg[0].geometry === undefined,
				P.body.geometry !== undefined,
				// One shared unit box under two different scales.
				P.body.geometry === P.leg[0].children[0].geometry,
				[P.body.scale.x, P.leg[0].children[0].scale.x],
				// A taper cannot be a scale, so it is its own geometry — sized
				// so that the widest radius is the one asked for.
				[P.tail.scale.x, P.tail.geometry.parameters.radiusTop],
				meshes,
			];
		`, "the assemble script ran");

		// Parent-first keys; the pair mirrored about x in [-x, +x] order; the
		// mesh at `at` inside its pivot; a 90 degree swing carrying it from
		// under the hip to behind it; one geometry, two scales; and collides on
		// every mesh.
		test::@check(
			value == "[\"root,spinner,body,leg,tail\",\"guy\",[-0.22,0.22],-0.23,[-0.22,0.23,0],[-0.22,0.46,-0.23],true,true,true,[0.78,0.26],[0.4,0.25],[false,false,false,false]]",
			"assemble names, mirrors and pivots; got %s", value
		);
	};
}

<*
 A typo in a part is refused, and the message says what a part takes.

 This is the failure the whole key list exists for. `colour` instead of `color`
 is a part that comes out white; `position` instead of `at` is a part at the
 origin. Neither throws anywhere, both are found by looking at the picture, and
 that is the loop this API exists to keep short — so the error names the part
 and lists the alternatives rather than saying that something was unexpected.
*>
fn void assemble_refuses_a_typo_and_lists_what_a_part_takes() @test
{
	@with_gpu_js(; three::JsRuntime* run)
	{
		String value = @value(run, `
			new three.Scene();
			const mat = new three.MeshLambertMaterial();
			const said = f => { try { f(); return 'no throw'; } catch (e) { return e.message; } };

			const typo = said(() => three.assemble({ head: { box: [1, 1, 1], colour: 1 } }, { material: mat }));
			const two = said(() => three.assemble({ head: { box: [1, 1, 1], sphere: 1 } }, { material: mat }));
			const none = said(() => three.assemble({ head: { at: [0, 1, 0] } }, { material: mat }));
			const axis = said(() => three.assemble({ head: { box: [1, 1, 1], mirror: 'w' } }, { material: mat }));
			const rooted = said(() => three.assemble({ root: { box: [1, 1, 1] } }, { material: mat }));
			const bare = said(() => three.assemble({ head: { box: [1, 1, 1] } }));
			const twice = said(() => three.assemble({
				a: { parts: { b: { box: [1, 1, 1] } } }, b: { box: [1, 1, 1] },
			}, { material: mat }));

			return [
				typo.includes("part 'head' has no 'colour'") && typo.includes('box, sphere, cylinder, cone, geometry'),
				two.includes("part 'head' has both a 'box' and a 'sphere'"),
				none.includes("part 'head' has no shape and no parts"),
				axis.includes("mirror: \"w\"") && axis.includes("'x', 'y' or 'z'"),
				rooted.includes("'root' is the Group everything hangs from"),
				bare.includes("part 'head' has no material"),
				twice.includes("two parts are called 'b'"),
			];
		`, "the refusal script ran");

		test::@check(value == "[true,true,true,true,true,true,true]",
			"every refusal names the part and what it may take; got %s", value);
	};
}
