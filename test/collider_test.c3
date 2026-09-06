<*
 What the file says collides — `KHR_physics_rigid_bodies` at load, and
 `instantiate({ physics: true })`.

	`c3c test --trust=full --test-filter three_tests::collider`

 There are two fixtures, both exported headlessly by the same Blender addon that
 writes the levels. `test/fixtures/hulls.glb` is the two shapes the other one has
 none of — a **convex hull** and a **cylinder**, with a slab under them.
 `test/fixtures/bodies.glb` is the rest: a ground slab with a Passive **mesh**
 body, a crate with a Passive **box**, a pillar with a Passive **capsule**, a
 crate with **motion** and a physics material, a **trigger** box, a plant with no
 body at all, and a **joint** between an anchor and a swinging crate. So every
 branch below is checked against what an exporter actually writes rather than
 against JSON typed here.

 **The one number that matters is `colliders`.** The engine's default is that
 every drawable mesh is collision geometry, which is right for a scene a script
 builds and wrong for a level — the Evil Forest is 580 colliders of which 449 are
 plants. With the option on the file decides, and the plant is out.
*>
module three_tests::collider;

import three;
import three_tests::device;
import vk;
import std::core::test;
import std::io::file;

const String FIXTURE = "test/fixtures/bodies.glb";

// A device, a runtime and a scene — the file has to be uploaded for its meshes
// to have the BVHs the index files on.
macro @with_gpu_js(; @body(three::JsRuntime* run))
{
	three::Renderer* renderer = device::borrow(200, 150);
	defer device::release();

	three::JsRuntime runtime;
	runtime.open(&renderer.pass, renderer)!!;
	defer runtime.close();

	@body(&runtime);
}

<*
 Without the option the file draws and collides exactly as it always did.

 The standing constraint at the bottom of `plan.md`: no existing scene changes.
 Eight meshes, eight colliders, and not one collision-only node — which is also
 what says the extension is read at load and applied only when asked.
*>
fn void a_file_without_the_option_collides_as_it_always_did() @test
{
	@with_gpu_js(; three::JsRuntime* run)
	{
		three::RunResult result = run.run(`
			const scene = new three.Scene();
			const asset = three.load('test/fixtures/bodies.glb');
			scene.add(asset.instantiate('bodies'));
			const s = three.stats();
			let proxies = 0;
			scene.traverse(o => { if (o.collisionOnly) proxies++; });
			return [s.colliders, s.drawCalls, proxies].join(',');
		`);
		defer result.free();

		test::@check(result.ok, "the file loaded: %s", result.error);
		test::@check(result.value == `"8,8,0"`, "eight meshes, eight colliders, no proxies; got %s", result.value);
	};
}

<*
 With the option on, the file's colliders decide the index and nothing else is
 in it.

 Seven colliders for seven authored bodies: the ground's mesh collider on the
 drawing itself, and a proxy each for the five implicit shapes and the trigger.
 The plant is drawn and swept by nothing, which is the whole point — and it is
 still eight draw calls, so nothing was taken out of the picture.
*>
fn void the_file_says_what_collides() @test
{
	@with_gpu_js(; three::JsRuntime* run)
	{
		three::RunResult result = run.run(`
			const scene = new three.Scene();
			const asset = three.load('test/fixtures/bodies.glb');
			const world = asset.instantiate('bodies', { physics: true });
			scene.add(world);
			const s = three.stats();
			const plant = scene.getObjectByName('plant');
			const ground = scene.getObjectByName('ground');
			const crate = scene.getObjectByName('crate');
			return [
				s.colliders, s.drawCalls,
				plant.collides, ground.collides, crate.collides,
			].join(',');
		`);
		defer result.free();

		test::@check(result.ok, "the file loaded: %s", result.error);
		test::@check(
			result.value == `"7,8,false,true,false"`,
			"seven authored colliders over eight drawings, the plant out and the ground in; got %s",
			result.value
		);
	};
}

<*
 An implicit shape is in every query and in no draw.

 The barrel-and-box case: the crate draws its own art and collides as the box the
 file named, so a raycast onto it reports the proxy — a node with a mesh, a
 `collisionOnly` flag, and no line in the draw list. Without the flag the proxy
 would have to be either visible, which is a grey box over the art, or hidden,
 which takes it out of every query at answer time.
*>
fn void an_implicit_shape_is_swept_and_never_drawn() @test
{
	@with_gpu_js(; three::JsRuntime* run)
	{
		three::RunResult result = run.run(`
			const scene = new three.Scene();
			const asset = three.load('test/fixtures/bodies.glb');
			scene.add(asset.instantiate('bodies', { physics: true }));
			// The crate sits at x = 3 with its box collider around it.
			const hit = scene.raycast([3, 6, 0], [0, -1, 0]);
			const proxy = scene.getObjectByName('crate.collider');
			// The pillar's capsule: 2 m of cylinder and a 0.5 m cap at each end,
			// on a node standing at y = 1, so its top is at 2.5.
			const capsule = scene.raycast([-3, 6, 0], [0, -1, 0]);
			return [
				hit.object.name, hit.point.y.toFixed(2),
				proxy.collisionOnly, proxy.collides, !!proxy.geometry,
				capsule.object.name, capsule.point.y.toFixed(2),
			].join(',');
		`);
		defer result.free();

		test::@check(result.ok, "the file loaded: %s", result.error);
		test::@check(
			result.value == `"crate.collider,1.00,true,true,true,pillar.collider,2.50"`,
			"the ray lands on each shape the file named, at its top; got %s",
			result.value
		);
	};
}

<*
 The character controller walks the file's collision geometry and nothing else.

 A capsule dropped on the open ground lands on it; the same capsule walked into
 the crate is stopped by the box the file named rather than by the crate's art,
 and walked into the plant it is stopped by nothing.
*>
fn void a_sweep_lands_on_the_ground_and_stops_at_the_box() @test
{
	@with_gpu_js(; three::JsRuntime* run)
	{
		three::RunResult result = run.run(`
			const scene = new three.Scene();
			const asset = three.load('test/fixtures/bodies.glb');
			scene.add(asset.instantiate('bodies', { physics: true }));
			const move = { radius: 0.3, height: 1.6, step: 0.3, slope: 50 };

			// Open ground, clear of everything the file put on it.
			const dropped = three.moveAndSlide([1.5, 5, 1.5], [0, -5, 0], move);
			// Walking east into the crate, whose box stands from x = 2.5.
			const into = three.moveAndSlide([1.4, 0.9, 0], [1.5, 0, 0], move);
			// The same walk through the plant, which the file did not name.
			const through = three.moveAndSlide([0, 0.9, 1.8], [0, 0, 2.0], move);

			return [
				dropped.grounded, dropped.position.y.toFixed(2),
				into.hit ? into.hit.name : 'nothing', into.position.x.toFixed(2),
				through.hit ? through.hit.name : 'nothing',
			].join(',');
		`);
		defer result.free();

		test::@check(result.ok, "the file loaded: %s", result.error);
		test::@check(
			result.value.contains("true,0.82,crate.collider,2."),
			"the capsule stands on the ground and is stopped by the box; got %s",
			result.value
		);
		test::@check(
			result.value.ends_with(`,nothing"`),
			"and walks through the plant, which the file did not name; got %s",
			result.value
		);
	};
}

<*
 The file's `motion` becomes a body, and it falls onto the file's ground.

 The half of the extension that is not the index: a Blender Active body arrives
 as a dynamic body with the mass the panel had, and the Passive bodies around it
 arrive as static ones so there is something for it to land on. Two seconds of
 frames at the fixed 60 Hz — the host clock is this test's, so nothing here
 depends on the machine.
*>
fn void the_files_motion_falls_onto_the_files_ground() @test
{
	@with_gpu_js(; three::JsRuntime* run)
	{
		three::RunResult built = run.run(`
			const scene = new three.Scene();
			const asset = three.load('test/fixtures/bodies.glb');
			scene.add(asset.instantiate('bodies', { physics: true }));
			globalThis.crate = scene.getObjectByName('falling_crate');
			three.setAnimationLoop(() => {});
			return [scene.physics.count, globalThis.crate.body.mass].join(',');
		`);
		defer built.free();
		test::@check(built.ok, "the file loaded: %s", built.error);
		test::@check(built.value == `"7,2"`, "seven bodies and the panel's mass of 2; got %s", built.value);

		for (int i = 1; i <= 120; i++) run.tick((double)i * (1000.0 / 60.0));

		three::RunResult after = run.run("return globalThis.crate.position.y;");
		defer after.free();
		test::@check(after.ok, "the crate read back: %s", after.error);

		double y = after.value.to_double() ?? 999.0;
		test::@check(y < 2.0, "the crate fell from y = 3, to %s", after.value);
		test::@check(y > 0.0, "and stopped on the file's ground rather than through it, y = %s", after.value);
	};
}

<*
 A `trigger` in the file is a volume in the solver.

 The falling crate drops through the trigger box on its way to the ground, and
 the enter names it — so the extension's `trigger` and `three.physics.add(...,
 { trigger: true })` are the same thing arriving by two doors.
*>
fn void a_trigger_in_the_file_fires() @test
{
	@with_gpu_js(; three::JsRuntime* run)
	{
		three::RunResult built = run.run(`
			const scene = new three.Scene();
			globalThis.seen = [];
			three.onTrigger(e => globalThis.seen.push(e.type + ':' + (e.trigger ? e.trigger.name : '?')));
			const asset = three.load('test/fixtures/bodies.glb');
			scene.add(asset.instantiate('bodies', { physics: true }));
			three.setAnimationLoop(() => {});
			return 'ok';
		`);
		defer built.free();
		test::@check(built.ok, "the file loaded: %s", built.error);

		for (int i = 1; i <= 30; i++) run.tick((double)i * (1000.0 / 60.0));

		three::RunResult fired = run.run("return globalThis.seen.join(',');");
		defer fired.free();
		test::@check(
			fired.value.contains("enter:trigger_zone"),
			"the file's trigger reported the crate falling through it: %s",
			fired.value
		);
	};
}

<*
 A body survives a trip through the exporter.

 The extension is written for the bodies the solver holds and read back by the
 loader that put them there, so a scene that says "this is a floor and this is a
 ball" can be saved and reopened saying the same thing. Nothing else gains a
 collider: `Node.collides` is on by default and true of nearly every node in
 nearly every scene, and writing one per node would say the file is nothing but
 colliders.
*>
fn void a_body_survives_the_export() @test
{
	String path = "build/physics_roundtrip.glb";
	defer (void)file::delete(path);

	@with_gpu_js(; three::JsRuntime* run)
	{
		three::RunResult result = run.run(`
			const scene = new three.Scene();
			const floor = new three.Mesh(new three.BoxGeometry(10, 1, 10));
			floor.name = 'floor';
			floor.position.y = -0.5;
			scene.add(floor);
			three.physics.add(floor, { shape: 'box', mass: 0, friction: 0.8 });

			const ball = new three.Mesh(new three.SphereGeometry(0.5, 16, 8));
			ball.name = 'ball';
			ball.position.y = 4;
			scene.add(ball);
			three.physics.add(ball, { shape: 'sphere', mass: 3 });

			const plain = new three.Mesh(new three.BoxGeometry(1, 1, 1));
			plain.name = 'scenery';
			plain.position.x = 5;
			scene.add(plain);

			scene.export('build/physics_roundtrip.glb');

			const back = three.load('build/physics_roundtrip.glb');
			return back.colliders
				.map(c => c.name + '|' + c.shape + '|' + (c.motion ? c.mass : 'static'))
				.join(',');
		`);
		defer result.free();

		test::@check(result.ok, "the scene exported and reloaded: %s", result.error);
		test::@check(
			result.value == `"floor.collider|box|static,ball.collider|sphere|3"`,
			"the floor and the ball came back and the scenery did not; got %s",
			result.value
		);
	};
}

<*
 A convex hull is swept as a hull, not as the drawing it was measured from.

 `test/fixtures/hulls.glb`'s rock is a 2 m cube with its top face poked down by
 0.8, so the drawing's centre is at y = 1.2 and the hull's top is the rim at
 y = 2.0. One ray straight down the middle tells the two apart, and the second
 instantiation — the same file with the option off — is the control: it hits the
 dent, because without the option every drawing is collision geometry.

 The proxy is the same arrangement an implicit shape gets: `collisionOnly`, in
 every query and in no draw list, with the rock's own art out of the index.
*>
fn void a_convex_hull_is_swept_as_a_hull() @test
{
	@with_gpu_js(; three::JsRuntime* run)
	{
		// The control first and in a run of its own — one scene is rendered at a
		// time, and `scene.raycast` asks the one that is.
		three::RunResult plain = run.run(`
			const scene = new three.Scene();
			scene.add(three.load('test/fixtures/hulls.glb').instantiate('hulls'));
			const dent = scene.raycast([0, 6, 0], [0, -1, 0]);
			return [dent.object.name, dent.point.y.toFixed(2)].join(',');
		`);
		defer plain.free();
		test::@check(plain.ok, "the file loaded: %s", plain.error);
		test::@check(
			plain.value == `"rock,1.20"`,
			"without the option the ray lands in the drawing's dent; got %s",
			plain.value
		);

		three::RunResult result = run.run(`
			const scene = new three.Scene();
			scene.add(three.load('test/fixtures/hulls.glb').instantiate('hulls', { physics: true }));
			const hull = scene.raycast([0, 6, 0], [0, -1, 0]);
			const rock = scene.getObjectByName('rock');
			const proxy = scene.getObjectByName('rock.collider');
			return [
				hull.object.name, hull.point.y.toFixed(2),
				rock.collides, proxy.collisionOnly, proxy.collides,
				three.stats().colliders,
			].join(',');
		`);
		defer result.free();

		test::@check(result.ok, "the file loaded: %s", result.error);
		test::@check(
			result.value == `"rock.collider,2.00,false,true,true,3"`,
			"the hull's rim, the drawing out of the index, three colliders; got %s",
			result.value
		);
	};
}

<*
 A cylinder is a shape the solver can hold — its own hull.

 The solver has a box, a sphere, a capsule, a hull and a heightfield, and a
 cylinder is none of them. It used to be reported and dropped, which left the
 file's drum with no body at all; it is now the hull of the proxy lathe, which is
 a sixteen-sided drum rather than a capsule with the corners rounded off.

 The drum is the fixture's one Active body, 1 m tall, dropped from y = 3 onto the
 ground at y = 0: it has to land at half its height and stay there. A body with no
 shape never moves at all, and a capsule of the same bounds would settle lower,
 so the resting height is what tells the three apart.
*>
fn void a_cylinder_becomes_the_nearest_shape_the_solver_holds() @test
{
	@with_gpu_js(; three::JsRuntime* run)
	{
		three::RunResult built = run.run(`
			const scene = new three.Scene();
			const asset = three.load('test/fixtures/hulls.glb');
			scene.add(asset.instantiate('hulls', { physics: true }));
			globalThis.drum = scene.getObjectByName('drum');
			three.setAnimationLoop(() => {});
			return [scene.physics.count, asset.colliders.length].join(',');
		`);
		defer built.free();
		test::@check(built.ok, "the file loaded: %s", built.error);
		test::@check(built.value == `"3,3"`, "all three of the file's colliders are bodies; got %s", built.value);

		for (int i = 1; i <= 150; i++) run.tick((double)i * (1000.0 / 60.0));

		three::RunResult after = run.run("return globalThis.drum.position.y;");
		defer after.free();
		test::@check(after.ok, "the drum read back: %s", after.error);

		double y = after.value.to_double() ?? 999.0;
		test::@check(y < 1.0, "the drum fell from y = 3, to %s", after.value);
		test::@check(y > 0.2, "and came to rest on its own flat end rather than through the ground, y = %s", after.value);
	};
}

<*
 A file with no `KHR_physics_rigid_bodies` in it is unchanged by the option.

 The other half of "no existing scene changes": passing `physics: true` at a file
 that says nothing about physics is not an error and is not a difference. It is
 what a script that turns the option on for a whole kit gets on the pieces that
 were never authored with it.
*>
fn void the_option_is_a_no_op_on_a_file_that_says_nothing() @test
{
	@with_gpu_js(; three::JsRuntime* run)
	{
		three::RunResult result = run.run(`
			const asset = three.load('test/fixtures/hierarchy.glb');
			const plain = new three.Scene();
			plain.add(asset.instantiate('plain'));
			const before = three.stats().colliders;

			const asked = new three.Scene();
			asked.add(asset.instantiate('asked', { physics: true }));
			const after = three.stats().colliders;
			return [before, after, asset.colliders.length].join(',');
		`);
		defer result.free();

		test::@check(result.ok, "the file loaded: %s", result.error);
		// `stats()` is the active scene's, and activating the second one leaves the
		// first standing — so the two numbers are the two scenes, not one twice.
		test::@check(result.value == `"4,4,0"`, "the same four colliders either way; got %s", result.value);
	};
}
