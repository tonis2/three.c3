<*
 Bulk spatial queries, the character controller, navigation and steering —
 `notes.md` §17.

	`c3c test --trust=full --test-noleak --test-filter three_tests::query`

 **What is worth testing here is the arithmetic that fails silently.** A query
 that returns nothing looks exactly like a scene with nothing in it; a character
 that cannot walk looks like a key binding; a path that goes through a wall
 looks like the wall being in the wrong place. None of them throw, and all of
 them are exact — so every check below is a number that can only come out right
 for one reason.

 Two of these exist because the implementation got them wrong first, and both
 are named for what went wrong rather than for what should happen:
 `a_capsule_resting_on_a_floor_can_still_walk` and
 `a_sweep_reaches_the_surface_it_is_converging_on`. See `Scene.sweep_capsule`.
*>
module three_tests::query;

import three;
import vk;
import std::core::test;
import std::math;
import std::math::vector;
import std::math::matrix;

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

// Run one script and hand back its value, checking it ran at all.
macro String @value(three::JsRuntime* run, String source, String what)
{
	three::RunResult result = run.run(source);
	defer result.free();
	test::@check(result.ok, "%s: %s", what, result.error);
	return result.value.copy(tmem);
}

// ============================================================================
// The index
// ============================================================================

<*
 A sphere query finds what is inside it and nothing else.

 The fixture is five boxes two units apart along X, so the answer for a radius
 is a count that changes at a known place — which is the only kind of assertion
 a broad-phase query can be held to without restating its implementation.
*>
fn void a_sphere_finds_what_is_inside_it() @test
{
	@with_gpu_js(; three::JsRuntime* run)
	{
		String value = @value(run, `
			const scene = new three.Scene();
			const g = new three.BoxGeometry(1, 1, 1);
			for (let i = 0; i < 5; i++) {
				const m = new three.Mesh(g);
				m.position.set(i * 2, 0, 0);
				m.name = 'b' + i;
				scene.add(m);
			}
			const near = three.query.sphere([0, 0, 0], 1.2).map(o => o.name).sort();
			const wider = three.query.sphere([0, 0, 0], 3).map(o => o.name).sort();
			const far = three.query.sphere([0, 20, 0], 1).length;
			return [near.join(), wider.join(), far];
		`, "the query script ran");

		// b0 is at the origin and b1's near face is at 1.5, so 1.2 reaches one
		// and 3 reaches two. The third asks the question that would pass for a
		// broken index: a query nowhere near anything must answer with nothing.
		test::@check(value == `["b0","b0,b1",0]`, "one, then two, then none; got %s", value);
	};
}

<*
 A box query and a sphere query agree about a box that straddles the boundary.

 They share the cell walk and differ only in the test applied afterwards, so a
 disagreement here is the sphere's exact closest-point test being wrong — which
 is invisible against any fixture whose contents are all well inside or well
 outside.
*>
fn void a_box_and_a_sphere_agree_on_the_edge() @test
{
	@with_gpu_js(; three::JsRuntime* run)
	{
		String value = @value(run, `
			const scene = new three.Scene();
			const m = new three.Mesh(new three.BoxGeometry(2, 2, 2));
			m.position.set(5, 0, 0);
			m.name = 'far';
			scene.add(m);

			// And one out at a corner, where a sphere and a box genuinely
			// differ: its nearest point is (4, 4, 0), which is 5.66 away.
			const corner = new three.Mesh(new three.BoxGeometry(2, 2, 2));
			corner.position.set(5, 5, 0);
			corner.name = 'corner';
			scene.add(corner);

			// The first box spans x 4..6. A sphere at the origin of radius 3.9
			// does not reach it; one of 4.1 does. A box query out to 4.1 does
			// too.
			return [
				three.query.sphere([0, 0, 0], 3.9).length,
				three.query.sphere([0, 0, 0], 4.1).map(o => o.name).join(),
				three.query.box({ min: [-4.1, -1, -1], max: [4.1, 1, 1] }).map(o => o.name).join(),
				// **The corner is the check that matters.** A box of +/-4.5
				// contains the corner box's near corner; a SPHERE of 4.5 does
				// not, because that corner is 5.66 out. A sphere query that
				// forgot its own test reports everything in the 2r cube, and
				// the cube's corners are 73% further away than the radius asked
				// for — which reads as the query being generous rather than as
				// it being wrong.
				three.query.box({ min: [-4.5, -4.5, -4.5], max: [4.5, 4.5, 4.5] }).map(o => o.name).sort().join(),
				three.query.sphere([0, 0, 0], 4.5).map(o => o.name).sort().join(),
			];
		`, "the edge script ran");

		test::@check(value == `[0,"far","far","corner,far","far"]`,
			"short, then reaching, then the box, then a corner the box finds and the sphere does not; got %s", value);
	};
}

<*
 The flat form fills a buffer the caller keeps, and says when it ran out.

 `full` is the only way a script can tell "there were exactly this many" from
 "there were more than I asked for", and a count equal to the capacity looks the
 same either way.
*>
fn void a_query_buffer_says_when_it_filled() @test
{
	@with_gpu_js(; three::JsRuntime* run)
	{
		String value = @value(run, `
			const scene = new three.Scene();
			const g = new three.BoxGeometry(1, 1, 1);
			for (let i = 0; i < 8; i++) {
				const m = new three.Mesh(g);
				m.position.set(i * 0.5, 0, 0);
				scene.add(m);
			}
			const small = three.query.buffer(3);
			const big = three.query.buffer(32);
			const a = three.query.sphere([2, 0, 0], 100, small);
			const b = three.query.sphere([2, 0, 0], 100, big);
			return [a, small.full, b, big.full, big.objects().length];
		`, "the buffer script ran");

		test::@check(value == "[3,true,8,false,8]",
			"three and full, then eight and not; got %s", value);
	};
}

<*
 The index notices a node that moved.

 The one way this whole layer can be wrong without being visibly broken: an
 index built before a move goes on answering about where things used to be, and
 every query is confidently, silently, one frame stale. `Scene.invalidate` is
 the single line that prevents it.
*>
fn void the_index_notices_a_node_that_moved() @test
{
	@with_gpu_js(; three::JsRuntime* run)
	{
		String value = @value(run, `
			const scene = new three.Scene();
			const m = new three.Mesh(new three.BoxGeometry(1, 1, 1));
			scene.add(m);

			const before = three.query.sphere([0, 0, 0], 1).length;
			m.position.set(50, 0, 0);
			const after = three.query.sphere([0, 0, 0], 1).length;
			const there = three.query.sphere([50, 0, 0], 1).length;

			// And a node that has left the scene entirely.
			scene.remove(m);
			const gone = three.query.sphere([50, 0, 0], 1).length;
			return [before, after, there, gone];
		`, "the invalidation script ran");

		test::@check(value == "[1,0,1,0]", "found, moved away, found there, removed; got %s", value);
	};
}

<*
 An ignored object takes its whole subtree out of a sweep.

 **The regression this exists for is a character colliding with its own chest.**
 `gather_triangles` took a single node, and a character is a Group of six or
 eight meshes — so the capsule was swept against the boxes standing inside it,
 `hit` came back as one of them, and the controller threw the character out
 along that normal. Ignoring the leaf you happen to name is not a fix, which is
 the middle case here: the torso is excluded and a leg answers instead.

 The distance is the assertion rather than `hit`, because a downward motion
 legitimately finds the floor: a capsule that collided with itself is
 depenetrated first and comes out somewhere it was never asked to go.
*>
fn void ignoring_an_object_ignores_its_subtree() @test
{
	@with_gpu_js(; three::JsRuntime* run)
	{
		String value = @value(run, `
			const scene = new three.Scene();
			const floor = new three.Mesh(new three.BoxGeometry(40, 1, 40));
			floor.position.y = -0.5;
			floor.name = 'floor';
			scene.add(floor);

			// A character of five meshes: a torso, a head and three limbs, all
			// of them inside the capsule that is about to be swept.
			const hero = new three.Group();
			hero.name = 'hero';
			const parts = [];
			for (const [name, y, x] of [['torso', 0.5, 0], ['head', 1.2, 0],
					['armL', 0.6, -0.4], ['armR', 0.6, 0.4], ['legs', -0.4, 0]]) {
				const m = new three.Mesh(new three.BoxGeometry(0.3, 0.6, 0.3));
				m.name = name;
				m.position.set(x, y, 0);
				hero.add(m);
				parts.push(name);
			}
			scene.add(hero);

			const opts = { radius: 0.4, height: 1.7, step: 0.4, slope: 52, skin: 0.02, snap: 0.4 };
			const from = [0, 0.85, 0], motion = [0.25, -0.1, 0];
			const moved = o => {
				const r = three.moveAndSlide(from, motion, o ? { ...opts, ignore: o } : opts);
				// Did it touch one of its own parts, and did it travel exactly
				// the motion it was given? Free motion is 0.25; a capsule that
				// started inside its own body is depenetrated first and comes
				// out somewhere it was never asked to go.
				const own = r.hit !== null && parts.includes(r.hit.name);
				return [own, Math.abs(r.position.x - (from[0] + motion[0])) < 1e-4];
			};
			return [moved(null), moved(scene.getObjectByName('torso')), moved(hero), moved([hero, floor])];
		`, "the ignore script ran");

		// Ignoring nothing collides with the character; ignoring the one leaf
		// you happened to name buys nothing, because five other meshes are still
		// there; ignoring the Group — or a list holding it — is clear and moves
		// exactly as asked.
		test::@check(value == `[[true,false],[true,false],[false,true],[false,true]]`,
			"twice hitting itself, then twice clear; got %s", value);
	};
}

<*
 A ninth ignored object is refused rather than dropped.

 A sweep quietly colliding with something it was told to pass through is a bug
 that reads as the controller misbehaving, and there is nothing a caller can do
 about it if they are not told. Eight is `MAX_IGNORED`, and ignoring an object
 ignores everything under it — so needing a ninth means the set is being used
 for something `Node.collides` should be doing.
*>
fn void a_ninth_ignored_object_is_refused() @test
{
	@with_gpu_js(; three::JsRuntime* run)
	{
		String value = @value(run, `
			const scene = new three.Scene();
			const m = new three.Mesh(new three.BoxGeometry(1, 1, 1));
			scene.add(m);
			const opts = { radius: 0.3, height: 1.5 };
			const tryN = n => {
				try {
					three.moveAndSlide([0, 5, 0], [0, -0.1, 0], { ...opts, ignore: new Array(n).fill(m) });
					return 'ok';
				} catch (e) { return e.constructor.name; }
			};
			return [tryN(8), tryN(9)];
		`, "the ignore-cap script ran");

		test::@check(value == `["ok","RangeError"]`, "eight is fine and nine is not; got %s", value);
	};
}

<*
 `collides = false` takes a drawable out of every spatial query and leaves it
 drawn.

 **The regression this exists for is a pickup that is a bollard.** Every mesh in
 the index is swept against, and `trigger: true` does not help because that is a
 physics property a sweep never sees — so the shape that worked before this flag
 was a visible thing plus an invisible volume beside it. The last two numbers
 are what makes this a different flag from `visible`: it still draws.
*>
fn void a_non_colliding_drawable_is_drawn_and_not_queried() @test
{
	@with_gpu_js(; three::JsRuntime* run)
	{
		String value = @value(run, `
			const scene = new three.Scene();
			const floor = new three.Mesh(new three.BoxGeometry(40, 1, 40));
			floor.position.y = -0.5;
			scene.add(floor);

			const pickup = new three.Mesh(new three.SphereGeometry(0.6, 12, 8));
			pickup.name = 'pickup';
			pickup.position.set(0, 0.6, 0);
			scene.add(pickup);

			const opts = { radius: 0.4, height: 1.7, step: 0.4, slope: 52, skin: 0.02, snap: 0.4 };
			const run = () => +three.moveAndSlide([-2, 0.85, 0], [3, 0, 0], opts).position.x.toFixed(2);

			const seenBefore = three.query.sphere([0, 0.6, 0], 0.2).length;
			const rayBefore = three.query.raycastAll([-5, 0.6, 0], [1, 0, 0]).length;
			const stoppedBefore = run();

			pickup.collides = false;

			const seenAfter = three.query.sphere([0, 0.6, 0], 0.2).length;
			const rayAfter = three.query.raycastAll([-5, 0.6, 0], [1, 0, 0]).length;
			const stoppedAfter = run();

			return [seenBefore, seenAfter, rayBefore, rayAfter,
				stoppedBefore < 0.9, stoppedAfter, pickup.visible, scene.stats().drawCalls];
		`, "the collides script ran");

		// Found then not, hit by the ray then not, blocked then walked through
		// to the full metre — and still visible, still drawn.
		test::@check(value == "[1,0,1,0,true,1,true,2]",
			"out of the queries and still on screen; got %s", value);
	};
}

<*
 `stats().colliders` is how many meshes every sweep is testing.

 **The regression this exists for is a level that is mostly scenery and does not
 look like one.** `collides` defaults to on, so decoration joins the index
 without anybody asking; `nodes` cannot show that, because a mesh out of the
 index is still a node.

 Proved by injection: count from `QueryIndex.entries` instead of from the nodes
 and `before`/`counted` both come back 0 — this script never runs a query, so
 the index has never been built. Drop the `collides` test out of
 `Scene.stats` and `after` stays at 2.
*>
fn void the_collider_count_is_what_a_script_watches() @test
{
	@with_gpu_js(; three::JsRuntime* run)
	{
		String value = @value(run, `
			const scene = new three.Scene();
			const empty = scene.stats().colliders;

			const floor = new three.Mesh(new three.BoxGeometry(40, 1, 40));
			scene.add(floor);
			const group = new three.Group();
			scene.add(group);
			const pickup = new three.Mesh(new three.SphereGeometry(0.6, 12, 8));
			group.add(pickup);

			// Nothing has queried, so the index behind these does not exist yet.
			const counted = scene.stats().colliders;
			const nodes = scene.stats().nodes;

			pickup.collides = false;

			return [empty, counted, nodes, scene.stats().colliders, scene.stats().nodes];
		`, "the collider-count script ran");

		// Two meshes and no Group among them, the Group and the root still nodes,
		// and saying so about the pickup moves one number and not the other.
		test::@check(value == "[0,2,4,1,4]",
			"colliders counts the index and nodes counts the scene; got %s", value);
	};
}

<*
 Hiding a node does not cost the index, and moving one does not rebuild it.

 There is no clock a script can read, so this checks the two things that are
 *observable* about the fix rather than the microseconds: that a hidden node
 stops being found and comes back exactly as it was, and that a sequence of
 write-then-ask answers correctly however it is interleaved. Both were true
 before the fix as well — what changed is the price — so this is a guard on the
 re-file being right, not on it being fast. `notes.md` §17 has the numbers.

 The interleaved half is the one that could actually break: a re-filed entry
 stays filed in the cells it used to cover, and the stamp is what stops it being
 reported twice.
*>
fn void a_hidden_node_and_a_moved_one_answer_correctly() @test
{
	@with_gpu_js(; three::JsRuntime* run)
	{
		String value = @value(run, `
			const scene = new three.Scene();
			const g = new three.BoxGeometry(1, 1, 1);
			const many = [];
			for (let i = 0; i < 40; i++) {
				const m = new three.Mesh(g);
				m.position.set(i * 3, 0, 0);
				m.name = 'm' + i;
				scene.add(m);
				many.push(m);
			}

			// Hiding and showing, with a query between every write.
			const hideSeen = [];
			for (const m of many.slice(0, 4)) {
				hideSeen.push(three.query.sphere([m.position.x, 0, 0], 0.6).length);
				m.visible = false;
				hideSeen.push(three.query.sphere([m.position.x, 0, 0], 0.6).length);
				m.visible = true;
				hideSeen.push(three.query.sphere([m.position.x, 0, 0], 0.6).length);
			}

			// Moving, with a query between every write. Each one is asked for
			// where it went AND for where it was.
			const moveSeen = [];
			for (let i = 0; i < 4; i++) {
				const m = many[i];
				const was = m.position.x;
				m.position.set(was, 40, 0);
				moveSeen.push(three.query.sphere([was, 40, 0], 0.6).length);
				moveSeen.push(three.query.sphere([was, 0, 0], 0.6).length);
			}

			// And past the loose cap, where it gives up and rebuilds: 200
			// writes with no query between them, then one question.
			for (let i = 0; i < many.length; i++) many[i].position.set(i * 3, 80, 0);
			const afterMany = [
				three.query.sphere([9, 80, 0], 0.6).length,
				three.query.sphere([9, 40, 0], 0.6).length,
				three.query.box({ min: [-2, 78, -2], max: [200, 82, 2] }).length,
			];
			return [hideSeen.join(), moveSeen.join(), afterMany.join()];
		`, "the invalidation script ran");

		test::@check(value == `["1,0,1,1,0,1,1,0,1,1,0,1","1,0,1,0,1,0,1,0","1,0,40"]`,
			"hidden and back, moved and found where it went, and all forty after the cap; got %s", value);
	};
}

<*
 `raycastAll` reports every node on the ray, and `raycast` reports the nearest
 of them.

 The pair is the check: if the index's nearest-cell-first walk were skipping
 anything, the two would disagree about which node is first.
*>
fn void a_ray_reports_everything_it_passes_through() @test
{
	@with_gpu_js(; three::JsRuntime* run)
	{
		String value = @value(run, `
			const scene = new three.Scene();
			const g = new three.BoxGeometry(1, 1, 1);
			for (let i = 0; i < 4; i++) {
				const m = new three.Mesh(g);
				m.position.set(0, 0, i * 3);
				m.name = 'wall' + i;
				scene.add(m);
			}
			const all = three.query.raycastAll([0, 0, -10], [0, 0, 1]);
			const names = all.map(h => h.name).sort().join();
			const near = scene.raycast([0, 0, -10], [0, 0, 1]);
			const limited = three.query.raycastAll([0, 0, -10], [0, 0, 1], { maxDistance: 11 }).length;
			return [all.length, names, near.name, +near.distance.toFixed(2), limited];
		`, "the raycastAll script ran");

		// The nearest box's near face is at z = -0.5, which is 9.5 from the
		// origin. maxDistance 11 reaches that one and the next at 12.5.
		test::@check(value == `[4,"wall0,wall1,wall2,wall3","wall0",9.5,1]`,
			"four hits, the nearest named, and the limit honoured; got %s", value);
	};
}

// ============================================================================
// The sweep
// ============================================================================

<*
 A sweep and a raycast agree about where a wall is, allowing for the radius.

 **This is the check that would have caught the sweep never converging.** The
 conservative advancement approaches contact asymptotically, so the test
 `distance <= clearance` was left one ulp short for ever and the sweep answered
 "no hit" for a wall it was a ten-thousandth of a millimetre from. A character
 walked through it, and nothing anywhere reported anything. See `SWEEP_TOUCH`.
*>
fn void a_sweep_reaches_the_surface_it_is_converging_on() @test
{
	@with_gpu_js(; three::JsRuntime* run)
	{
		String value = @value(run, `
			const scene = new three.Scene();
			const wall = new three.Mesh(new three.BoxGeometry(4, 4, 1));
			wall.position.set(0, 0, 3);
			wall.name = 'wall';
			scene.add(wall);

			const ray = scene.raycast([0, 0, -5], [0, 0, 1]);
			const hit = three.query.sweep([0, 0, -5], [0, 0, 5], { radius: 0.4 });
			return [
				hit === null ? 'MISSED' : hit.name,
				+ray.distance.toFixed(3),
				+hit.distance.toFixed(3),
				+hit.normal.z.toFixed(3),
			];
		`, "the sweep script ran");

		// The face is 7.5 along the ray; a sphere of 0.4 stops 0.4 short of it.
		test::@check(value == `["wall",7.5,7.1,-1]`,
			"the sweep stops one radius short of the face the ray found; got %s", value);
	};
}

// A sweep with nothing in the way answers null rather than a hit at the end.
fn void a_clear_sweep_is_not_a_hit() @test
{
	@with_gpu_js(; three::JsRuntime* run)
	{
		String value = @value(run, `
			const scene = new three.Scene();
			const floor = new three.Mesh(new three.BoxGeometry(20, 1, 20));
			floor.position.y = -0.5;
			scene.add(floor);
			return [
				three.query.sweep([0, 5, -8], [0, 5, 8], { radius: 0.5 }) === null,
				three.query.sweep([0, 5, 0], [0, -5, 0], { radius: 0.5 }) !== null,
			];
		`, "the clear-sweep script ran");

		test::@check(value == "[true,true]", "over the floor is clear, into it is not; got %s", value);
	};
}

// ============================================================================
// The character controller
// ============================================================================

<*
 A capsule standing on a floor can walk along it.

 **The bug this is named for.** A capsule resting on a floor is permanently
 within its own clearance of it, so a sweep that treats "within reach" as "in
 the way" reports a hit at fraction zero on every frame, the slide has nothing
 to project, and the character is pinned to the spot it spawned on — grounded,
 upright, and unable to move. Nothing throws and nothing is visibly wrong except
 that the keys do nothing.

 The fix is that only a contact the motion is pushing *into* stops anything; see
 `Scene.sweep_capsule`. A floor underfoot has a closing rate of nought for a
 horizontal step.
*>
fn void a_capsule_resting_on_a_floor_can_still_walk() @test
{
	@with_gpu_js(; three::JsRuntime* run)
	{
		String value = @value(run, `
			const scene = new three.Scene();
			const floor = new three.Mesh(new three.BoxGeometry(40, 1, 40));
			floor.position.y = -0.5;
			scene.add(floor);

			let p = [0, 0.9, 0];
			let grounded = false;
			for (let i = 0; i < 30; i++) {
				const r = three.moveAndSlide(p, [0.1, -0.02, 0], { radius: 0.3, height: 1.8 });
				p = r.position.toArray();
				grounded = r.grounded;
			}
			return [+p[0].toFixed(2), +p[1].toFixed(2), grounded];
		`, "the walking script ran");

		// Thirty steps of 0.1 is three units, and the feet stay on the floor.
		// 0.92 rather than 0.9: the capsule's centre sits radius + half above
		// the surface, plus the default skin — see `MoveOptions.skin` for why a
		// character never rests at exactly zero clearance.
		test::@check(value == "[3,0.92,true]",
			"it walked three units and stayed on the floor; got %s", value);
	};
}

<*
 A wall stops the character and a slope does not.

 The same motion into two surfaces that differ only in their angle, so the
 assertion is about the slope limit and about nothing else. A controller that
 treated every contact as a wall would stop on both; one that treated every
 contact as ground would climb both.
*>
fn void a_wall_stops_a_character_and_a_ramp_does_not() @test
{
	@with_gpu_js(; three::JsRuntime* run)
	{
		String value = @value(run, `
			const scene = new three.Scene();
			const floor = new three.Mesh(new three.BoxGeometry(40, 1, 40));
			floor.position.y = -0.5;
			scene.add(floor);

			const wall = new three.Mesh(new three.BoxGeometry(1, 6, 20));
			wall.position.set(4, 3, 0);
			scene.add(wall);

			let p = [0, 0.9, 0];
			for (let i = 0; i < 80; i++) {
				const r = three.moveAndSlide(p, [0.1, -0.02, 0], { radius: 0.3, height: 1.8 });
				p = r.position.toArray();
			}
			// The wall's near face is at x = 3.5, so a 0.3 capsule stops at 3.2.
			const stopped = p[0];

			// A ramp of 20 degrees, which is under the default 50-degree limit.
			const scene2 = new three.Scene();
			const ground = new three.Mesh(new three.BoxGeometry(40, 1, 40));
			ground.position.y = -0.5;
			scene2.add(ground);
			// A ramp of 20 degrees, well under the default 50-degree limit.
			const ramp = new three.Mesh(new three.BoxGeometry(20, 1, 20));
			ramp.position.set(10, 2, 0);
			ramp.rotation.z = 20 * Math.PI / 180;
			scene2.add(ramp);

			let q = [2, 0.9, 0];
			let climbedGrounded = false;
			let slope = 0;
			for (let i = 0; i < 120; i++) {
				const r = three.moveAndSlide(q, [0.1, -0.05, 0], { radius: 0.3, height: 1.8 });
				q = r.position.toArray();
				climbedGrounded = r.grounded;
				slope = r.slope;
			}
			return [+stopped.toFixed(2), q[0] > 6, q[1] > 2, climbedGrounded, Math.round(slope)];
		`, "the wall-and-ramp script ran");

		// 3.18 rather than 3.5 minus the radius: the skin holds the capsule
		// clear of the face it stopped against. The slope is the check that
		// matters most here — a controller can climb a ramp by accident, and
		// reporting 20 degrees on it means it knows what it is standing on.
		test::@check(value == "[3.18,true,true,true,20]",
			"stopped at the wall, walked up the ramp, and knows the slope; got %s", value);
	};
}

<*
 A ledge under the step height is climbed, and one over it is not.

 Written as two runs of the same loop against two ledge heights, because the
 climb is three sweeps and the interesting failure is that it succeeds for
 *both* — a step-up that skips the "did it land higher" check will happily lift
 a character onto the top of a wall.
*>
fn void a_ledge_under_the_step_height_is_climbed() @test
{
	@with_gpu_js(; three::JsRuntime* run)
	{
		String value = @value(run, `
			function walkAt(ledgeHeight) {
				const scene = new three.Scene();
				const floor = new three.Mesh(new three.BoxGeometry(40, 1, 40));
				floor.position.y = -0.5;
				scene.add(floor);

				const step = new three.Mesh(new three.BoxGeometry(10, ledgeHeight, 20));
				step.position.set(9, ledgeHeight / 2, 0);
				scene.add(step);

				let p = [0, 0.9, 0];
				for (let i = 0; i < 90; i++) {
					const r = three.moveAndSlide(p, [0.1, -0.05, 0], { radius: 0.3, height: 1.8, step: 0.4 });
					p = r.position.toArray();
				}
				return p;
			}
			const low = walkAt(0.3);
			const high = walkAt(1.5);
			return [low[0] > 5, +low[1].toFixed(2), high[0] < 4.5, +high[1].toFixed(2)];
		`, "the ledge script ran");

		// A 0.3 ledge is walked onto and the capsule's centre rises to it; a
		// 1.5 wall stops it short with the centre still at floor height. Both
		// heights carry the skin — see `a_capsule_resting_on_a_floor_can_still_walk`.
		test::@check(value == "[true,1.22,true,0.92]",
			"the low ledge was climbed and the high one was not; got %s", value);
	};
}

// A character that walks off the edge of a platform falls rather than hovering.
fn void walking_off_a_ledge_stops_being_grounded() @test
{
	@with_gpu_js(; three::JsRuntime* run)
	{
		String value = @value(run, `
			const scene = new three.Scene();
			const platform = new three.Mesh(new three.BoxGeometry(6, 1, 6));
			platform.position.y = -0.5;
			scene.add(platform);

			let p = [0, 0.9, 0];
			let grounded = [];
			for (let i = 0; i < 60; i++) {
				const r = three.moveAndSlide(p, [0.15, -0.08, 0], { radius: 0.3, height: 1.8 });
				p = r.position.toArray();
				grounded.push(r.grounded);
			}
			return [grounded[0], grounded[59], p[1] < 0];
		`, "the ledge-fall script ran");

		test::@check(value == "[true,false,true]",
			"grounded on the platform, airborne past its edge, and below it; got %s", value);
	};
}

// ============================================================================
// Navigation
// ============================================================================

<*
 A bake finds standing room and refuses to find it inside a wall.

 The counts are not asserted — they are a property of the cell size and the
 fixture, and pinning them would be pinning the implementation. What is asserted
 is the shape of the answer: there is walkable space, it is less than the solid
 space, and a point inside a wall is not on it.
*>
fn void a_bake_finds_the_floor_and_not_the_wall() @test
{
	@with_gpu_js(; three::JsRuntime* run)
	{
		String value = @value(run, `
			const scene = new three.Scene();
			const floor = new three.Mesh(new three.BoxGeometry(20, 1, 20));
			floor.position.y = -0.5;
			scene.add(floor);
			const wall = new three.Mesh(new three.BoxGeometry(1, 4, 12));
			wall.position.set(0, 2, 0);
			scene.add(wall);

			const stats = three.nav.bake({ cell: 0.5, radius: 0.3, height: 1.8 });
			const field = three.nav.field([[8, 0, 0]]);
			const answer = [
				stats !== null,
				stats.walkable > 0,
				Number.isFinite(field.cost([-8, 0, 0])),
				Number.isFinite(field.cost([0, 2, 0])),
				Number.isFinite(field.cost([0, 60, 0])),
			];
			field.dispose();
			return answer;
		`, "the bake script ran");

		test::@check(value == "[true,true,true,false,false]",
			"a bake, walkable cells, a reachable floor, and nothing inside the wall or in the sky; got %s", value);
	};
}

<*
 The next level's paths can be solved before the level is shown.

 **The regression this exists for is a loading stall at a level boundary.** A
 bake is voxelization over one scene's own triangles and needs no frame at all,
 which is the half of per-scene ownership that genuinely works ahead of time —
 unlike a physics world, which is correct but motionless until its scene is the
 one being stepped. So the swap is `activate()` and nothing else: the field is
 already solved and answers the same distances after it as before.

 Proved by injection: put `nav` and `nav_fields` back on `JsRuntime` and the
 second bake overwrites the first, so `costBefore` and `costAfter` disagree and
 the shown level walks the hidden one's grid.
*>
fn void a_bake_on_a_scene_that_is_not_shown_is_ready_when_it_is() @test
{
	@with_gpu_js(; three::JsRuntime* run)
	{
		String value = @value(run, `
			// The level on screen: a floor with a wall across it.
			const here = new three.Scene();
			const hereFloor = new three.Mesh(new three.BoxGeometry(20, 1, 20));
			hereFloor.position.y = -0.5;
			here.add(hereFloor);
			const wall = new three.Mesh(new three.BoxGeometry(1, 4, 12));
			wall.position.set(0, 2, 0);
			here.add(wall);
			const hereBake = here.nav.bake({ cell: 0.5, radius: 0.3, height: 1.8 });

			// The next one, built and baked while the first is still the one being
			// rendered.
			const next = new three.Scene();
			next.activate();
			here.activate();

			const nextFloor = new three.Mesh(new three.BoxGeometry(20, 1, 20));
			nextFloor.position.y = -0.5;
			next.add(nextFloor);
			const nextBake = next.nav.bake({ cell: 0.5, radius: 0.3, height: 1.8 });
			const field = next.nav.field([[8, 0, 0]]);
			const costBefore = field.cost([-8, 0, 0]);

			// Baking the hidden level did not touch the shown one.
			const stillHere = here.nav.stats() !== null;
			const hereField = here.nav.field([[8, 0, 0]]);
			const wallStillBlocks = !Number.isFinite(hereField.cost([0, 2, 0]));

			next.activate();
			const costAfter = field.cost([-8, 0, 0]);

			const answer = [
				hereBake !== null,
				nextBake !== null,
				stillHere,
				wallStillBlocks,
				Number.isFinite(costBefore),
				costAfter === costBefore,
			];
			hereField.dispose();
			field.dispose();
			here.dispose();
			return answer;
		`, "the two-scene bake script ran");

		test::@check(value == "[true,true,true,true,true,true]",
			"both scenes baked, neither touched the other, and the field survived the swap; got %s", value);
	};
}

<*
 A bake keeps a slope connected to itself, and says how many pieces it is in.

 **The regression this exists for cost half a session.** The erosion that
 reserves the agent's width used to dilate the whole *solid* set horizontally;
 the moment `ceil(radius / cell - 0.5)` rounds up to 1, a descending floor comes
 apart, because the uphill column's floor cell sits at the *walkable* layer of
 the column beside it and growing it sideways blocks exactly the cell the
 downhill agent had to stand in. It is invisible on flat ground — there is no
 floor cell at the walkable layer to grow — which is why it survived every test
 until a level had a hill in it.

 The fixture is a 60-unit ramp climbing six, which is 5.7 degrees: far inside
 any slope limit, and steep enough that the layers differ. Three radii, one of
 which rounds `grow` to zero and was the only one that ever worked. Before the
 fix, the defaults gave 13 regions and a far end that could not be reached.

 `components` is checked as well as the reachability, because it is the counter
 that makes this findable: every other number a fragmented bake reports looks
 healthy.
*>
fn void a_ramp_stays_one_region_at_any_agent_radius() @test
{
	@with_gpu_js(; three::JsRuntime* run)
	{
		String value = @value(run, `
			const scene = new three.Scene();
			const flatA = new three.Mesh(new three.BoxGeometry(20, 1, 12));
			flatA.position.set(-40, -0.5, 0);
			scene.add(flatA);
			const ramp = new three.Mesh(new three.BoxGeometry(61, 1, 12));
			ramp.position.set(0, 2.5, 0);
			ramp.rotation.z = Math.atan2(6, 60);
			scene.add(ramp);
			const flatB = new three.Mesh(new three.BoxGeometry(20, 1, 12));
			flatB.position.set(40, 5.5, 0);
			scene.add(flatB);

			const bounds = { min: [-55, -4, -10], max: [55, 12, 10] };
			const ask = (radius, cell) => {
				const s = three.nav.bake({ cell, radius, height: 1.8, slope: 50, bounds });
				const f = three.nav.field([40, 6.2, 0]);
				// The bottom of the ramp, and the direction out of it: a graph
				// in pieces answers "unreachable" and points nowhere.
				const cost = f.cost([-40, 0.1, 0]);
				const dir = f.direction([-40, 0.1, 0]);
				f.dispose();
				return [s.components, s.largest === s.walkable, Number.isFinite(cost), dir.x > 0.5];
			};
			return [ask(0.35, 0.5), ask(0.43, 0.6), ask(0.30, 0.6), ask(0.6, 0.5)];
		`, "the ramp bake script ran");

		test::@check(value == `[[1,true,true,true],[1,true,true,true],[1,true,true,true],[1,true,true,true]]`,
			"one region and a reachable far end at every radius; got %s", value);
	};
}

<*
 `components` counts the pieces, and a gap really does make two.

 The test above would pass on a `components` hard-coded to 1, so this is the
 other half: two floors with a gap between them are two regions, one floor is
 one, and `largest` is the bigger of the two rather than the total.
*>
fn void components_counts_what_a_walk_cannot_cross() @test
{
	@with_gpu_js(; three::JsRuntime* run)
	{
		String value = @value(run, `
			const scene = new three.Scene();
			const a = new three.Mesh(new three.BoxGeometry(20, 1, 10));
			a.position.set(-15, -0.5, 0);
			scene.add(a);
			const b = new three.Mesh(new three.BoxGeometry(10, 1, 10));
			b.position.set(15, -0.5, 0);
			scene.add(b);

			const bounds = { min: [-30, -4, -8], max: [25, 6, 8] };
			const split = three.nav.bake({ cell: 0.5, radius: 0.3, height: 1.8, bounds });

			// Bridge the gap and bake again: the same geometry, now crossable.
			const bridge = new three.Mesh(new three.BoxGeometry(18, 1, 4));
			bridge.position.set(2.5, -0.5, 0);
			scene.add(bridge);
			const joined = three.nav.bake({ cell: 0.5, radius: 0.3, height: 1.8, bounds });

			return [
				split.components, split.largest < split.walkable, split.largest > split.walkable / 2,
				joined.components, joined.largest === joined.walkable,
			];
		`, "the components script ran");

		test::@check(value == "[2,true,true,1,true]",
			"two islands with the bigger one named, then one; got %s", value);
	};
}

<*
 A path goes round a wall rather than through it, and is shortened.

 Both halves matter and they pull in opposite directions: an unshortened path is
 a staircase of cell centres, and a path shortened without checking the geometry
 is a straight line through the wall. The length being longer than the straight
 line is what says it went round; the waypoint count being small is what says it
 was pulled tight.
*>
fn void a_path_goes_round_a_wall_and_is_pulled_tight() @test
{
	@with_gpu_js(; three::JsRuntime* run)
	{
		String value = @value(run, `
			const scene = new three.Scene();
			const floor = new three.Mesh(new three.BoxGeometry(30, 1, 30));
			floor.position.y = -0.5;
			scene.add(floor);
			// A wall across the middle, with a gap at one end.
			const wall = new three.Mesh(new three.BoxGeometry(1, 4, 20));
			wall.position.set(0, 2, -3);
			scene.add(wall);

			three.nav.bake({ cell: 0.5, radius: 0.3, height: 1.8 });
			const path = three.nav.path([-10, 0, 0], [10, 0, 0]);

			let walked = 0;
			for (let i = 1; i < path.length; i++) {
				walked += Math.hypot(path[i].x - path[i - 1].x, path[i].z - path[i - 1].z);
			}
			// Nothing on the route may be inside the wall: x within 0.5 of the
			// wall's plane AND z inside its span.
			const through = path.some(p => Math.abs(p.x) < 0.8 && p.z > -13 && p.z < 7);
			return [path.length > 1, path.length < 12, walked > 20.5, through];
		`, "the path script ran");

		test::@check(value == "[true,true,true,false]",
			"a short route, longer than the straight line, and clear of the wall; got %s", value);
	};
}

<*
 A field answers for every agent, and answers the same thing a path does.

 The two verbs are meant to be two views of one solve. If they disagreed, the
 split §17 argues for would be a split between two pathfinders.
*>
fn void a_field_and_a_path_agree_about_the_way() @test
{
	@with_gpu_js(; three::JsRuntime* run)
	{
		String value = @value(run, `
			const scene = new three.Scene();
			const floor = new three.Mesh(new three.BoxGeometry(30, 1, 30));
			floor.position.y = -0.5;
			scene.add(floor);

			three.nav.bake({ cell: 0.5, radius: 0.3, height: 1.8 });
			const field = three.nav.field([[10, 0, 0]]);

			const here = field.direction([-10, 0, 0]);
			const path = three.nav.path([-10, 0, 0], [10, 0, 0]);
			const towards = path.length > 1
				? Math.sign(path[1].x - path[0].x)
				: 0;

			const cost = field.cost([-10, 0, 0]);
			const nearer = field.cost([0, 0, 0]);
			const answer = [
				+here.x.toFixed(2), +here.z.toFixed(2), towards,
				cost > nearer, Number.isFinite(cost),
			];
			field.dispose();
			return answer;
		`, "the field script ran");

		test::@check(value == "[1,0,1,true,true]",
			"the field points along +x, the path starts that way, and the cost falls; got %s", value);
	};
}

// A disposed field answers "unreachable" rather than reading freed memory.
fn void a_disposed_field_answers_rather_than_reads() @test
{
	@with_gpu_js(; three::JsRuntime* run)
	{
		String value = @value(run, `
			const scene = new three.Scene();
			const floor = new three.Mesh(new three.BoxGeometry(20, 1, 20));
			floor.position.y = -0.5;
			scene.add(floor);
			three.nav.bake({ cell: 0.5 });

			const field = three.nav.field([[5, 0, 0]]);
			const before = Number.isFinite(field.cost([-5, 0, 0]));
			field.dispose();
			const after = field.cost([-5, 0, 0]);
			return [before, field.alive, after === Infinity, field.dispose()];
		`, "the dispose script ran");

		test::@check(value == "[true,false,true,false]",
			"reachable, then disposed, then unreachable, and a second dispose is false; got %s", value);
	};
}

// ============================================================================
// Steering
// ============================================================================

<*
 Steering writes one velocity per agent, and separation pushes two apart.

 The seek is asserted by direction rather than by magnitude, and the separation
 by the two agents' velocities being *different* — an implementation that
 summed the neighbour push into the wrong agent, or that clamped before adding
 it, gives them the same answer.
*>
fn void steering_seeks_a_goal_and_pushes_neighbours_apart() @test
{
	@with_gpu_js(; three::JsRuntime* run)
	{
		String value = @value(run, `
			const p = new Float32Array([0, 0, 0,  0.2, 0, 0]);
			const v = new Float32Array(6);

			three.steer(p, v, { goal: [10, 0, 0], maxSpeed: 2 });
			const seekX = +v[0].toFixed(2);
			const flat = v[1] === 0;

			three.steer(p, v, { goal: [10, 0, 0], maxSpeed: 2, separation: 1, separationWeight: 2 });
			// The first agent is pushed back along -x by its neighbour and the
			// second is pushed forward, so they cannot come out equal.
			const apart = v[0] < v[3];
			const capped = Math.hypot(v[0], v[1], v[2]) <= 2.0001;
			return [seekX, flat, apart, capped];
		`, "the steering script ran");

		test::@check(value == "[2,true,true,true]",
			"full speed towards the goal, flat, pushed apart, and clamped; got %s", value);
	};
}

<*
 Arrive slows an agent inside the radius and stops it at the goal.

 Without it a crowd orbits its destination for ever, which looks like the
 pathfinder oscillating rather than like a missing taper.
*>
fn void arrive_slows_an_agent_as_it_gets_there() @test
{
	@with_gpu_js(; three::JsRuntime* run)
	{
		String value = @value(run, `
			const far = new Float32Array([0, 0, 0]);
			const near = new Float32Array([9.5, 0, 0]);
			const v = new Float32Array(3);

			three.steer(far, v, { goal: [10, 0, 0], maxSpeed: 4, arrive: 2 });
			const fast = +Math.hypot(v[0], v[1], v[2]).toFixed(2);
			three.steer(near, v, { goal: [10, 0, 0], maxSpeed: 4, arrive: 2 });
			const slow = +Math.hypot(v[0], v[1], v[2]).toFixed(2);
			return [fast, slow];
		`, "the arrive script ran");

		// Ten units out is well past the radius, so full speed; half a unit out
		// is a quarter of the way in, so a quarter of the speed.
		test::@check(value == "[4,1]", "full speed far out and a quarter close in; got %s", value);
	};
}

// ============================================================================
// The batched write
// ============================================================================

<*
 A batch moves what it was given and skips what has left the scene.

 The skip is the half worth testing: a crowd where one agent was removed this
 frame is ordinary, and a batch that threw would abandon the rest of it with no
 way to say which.
*>
fn void a_batch_moves_what_is_left_of_it() @test
{
	@with_gpu_js(; three::JsRuntime* run)
	{
		String value = @value(run, `
			const scene = new three.Scene();
			const g = new three.BoxGeometry(1, 1, 1);
			const all = [];
			for (let i = 0; i < 6; i++) {
				const m = new three.Mesh(g);
				m.position.set(i, 0, 0);
				scene.add(m);
				all.push(m);
			}
			const batch = three.batch(all);
			// Seeded from where they are, so a flush with no edit moves nothing.
			const seeded = batch.positions[3] === 1 && batch.positions[15] === 5;

			for (let i = 0; i < 6; i++) batch.positions[i * 3 + 1] = 7;
			const wrote = batch.flush();
			const lifted = all[2].getWorldPosition().y;

			scene.remove(all[4]);
			for (let i = 0; i < 6; i++) batch.positions[i * 3 + 1] = 9;
			const after = batch.flush();
			return [seeded, wrote, lifted, after, all[0].getWorldPosition().y];
		`, "the batch script ran");

		test::@check(value == "[true,6,7,5,9]",
			"seeded, six written, then five with one gone; got %s", value);
	};
}

// ============================================================================
// The camera's third angle
// ============================================================================

<*
 Roll turns the picture and leaves the aim alone.

 A camera that rolled by moving the target or the angles would pass any test
 that only looked at the picture. So this asserts the two halves separately:
 the up vector turns, and yaw, pitch and the eye do not move at all.
*>
fn void roll_turns_the_picture_and_not_the_aim() @test
{
	three::Camera camera = three::default_camera();
	camera.yaw = 0;
	camera.pitch = 0;
	camera.distance = 5;

	Vec3 level = camera.up();
	Vec3 eye_before = camera.eye();

	camera.roll = 90.0f;
	Vec3 rolled = camera.up();
	Vec3 eye_after = camera.eye();

	test::@check(math::abs(level.y - 1.0f) < 1e-5f, "level up is +Y, got %s", level);
	// At yaw 0 the camera looks down -Z, so a 90-degree roll puts up on the
	// screen's right, which in world terms is -X for this basis.
	test::@check(math::abs(rolled.y) < 1e-5f, "a quarter turn leaves no +Y in the up vector, got %s", rolled);
	test::@check(math::abs(math::abs(rolled.x) - 1.0f) < 1e-5f, "and it is along X, got %s", rolled);
	test::@check((eye_before - eye_after).length() < 1e-5f, "the eye did not move");
	test::@check(camera.yaw == 0.0f && camera.pitch == 0.0f, "and neither did the aim");

	// The view matrix has to follow, or `Camera.up` is a number nothing reads.
	Matrix4f view = camera.view();
	test::@check(math::abs(view.m[1]) > 0.5f, "the view matrix carries the roll");
}

<*
 A follow offset in the node's own frame rides the node's rotation.

 The world-space offset is what a head is and is the default; the local one is
 what a cockpit is, and the difference only shows once the thing being followed
 has turned. So the check is one quarter turn: a world offset stays put and a
 local one goes round with it.
*>
fn void a_local_follow_offset_rides_the_rotation() @test
{
	three::Camera world_camera = three::default_camera();
	three::Camera local_camera = three::default_camera();

	// A node rotated a quarter turn about +Y, at the origin.
	Matrix4f turned = matrix::IDENTITY4{float}.rotate_y(math::deg_to_rad(90.0f));

	three::CameraFollow world_follow = { .active = true, .offset = { 0, 0, 2 } };
	three::CameraFollow local_follow = { .active = true, .offset = { 0, 0, 2 }, .local_offset = true };

	world_follow.apply_world(&world_camera, turned, 0);
	local_follow.apply_world(&local_camera, turned, 0);

	test::@check((world_camera.target - (Vec3){ 0, 0, 2 }).length() < 1e-4f,
		"a world offset ignores the rotation, got %s", world_camera.target);
	test::@check((local_camera.target - (Vec3){ 2, 0, 0 }).length() < 1e-4f,
		"a local offset turns with it, got %s", local_camera.target);
}

// ============================================================================
// Damping and curves
// ============================================================================

<*
 `damp` closes the same fraction of the gap per second at any frame rate.

 The claim the verb exists to make. `x += (target - x) * 0.1` fails this by a
 factor of two between 60 Hz and 120, and a chase tuned on one machine is a
 different chase on another — which reads as taste rather than as a bug, so
 nobody files it.
*>
fn void damping_is_the_same_at_any_frame_rate() @test
{
	@with_gpu_js(; three::JsRuntime* run)
	{
		String value = @value(run, `
			function chase(steps, dt) {
				let x = 0;
				for (let i = 0; i < steps; i++) x = three.damp(x, 100, 3, dt);
				return x;
			}
			const slow = chase(60, 1 / 60);
			const fast = chase(240, 1 / 240);
			// One second at lambda 3 leaves e^-3 of the gap.
			const exact = 100 * (1 - Math.exp(-3));
			return [
				Math.abs(slow - fast) < 0.001,
				Math.abs(slow - exact) < 0.001,
				three.damp(5, 10, 3, 0),
				+three.dampAngle(3.1, -3.1, 50, 1).toFixed(3),
			];
		`, "the damping script ran");

		// dampAngle takes the short way: +3.1 to -3.1 is 0.083 radians the near
		// way round, so a fast damp lands just past +Math.PI rather than near 0.
		test::@check(value == "[true,true,5,3.183]",
			"the same at both rates, exact, still at zero dt, and the short way round; got %s", value);
	};
}

<*
 A curve walked by length is not a curve walked by its own parameter.

 The distinction `CatmullRomCurve3` is documented on, and the one that makes
 hand-written rail code look wrong. The fixture has one long segment and one
 short one, so `getPoint(0.5)` lands at the join and `getPointAt(0.5)` lands
 halfway along the *length*, which is inside the long one.
*>
fn void a_curve_walked_by_length_is_not_walked_by_t() @test
{
	@with_gpu_js(; three::JsRuntime* run)
	{
		String value = @value(run, `
			const curve = new three.CatmullRomCurve3([[0, 0, 0], [10, 0, 0], [11, 0, 0]]);
			const byT = curve.getPoint(0.5).x;
			const byLength = curve.getPointAt(0.5).x;
			const ends = [curve.getPoint(0).x, curve.getPoint(1).x];
			const tangent = curve.getTangent(0.1);
			return [
				+byT.toFixed(1), byLength < byT,
				ends[0], +ends[1].toFixed(1),
				+tangent.x.toFixed(2),
				+curve.getLength().toFixed(1),
				curve.getPoints(4).length,
			];
		`, "the curve script ran");

		// t = 0.5 is the join at x = 10; half the length is around x = 5.5.
		test::@check(value == "[10,true,0,11,1,11,5]",
			"the join by t, earlier by length, exact ends, a +x tangent; got %s", value);
	};
}

<*
 `smoothDamp` needs its state to outlive the frame, and shows it.

 The one way to use this verb and see nothing: a state object created inside the
 loop is a spring re-launched from rest on every tick, which arrives later than
 one that keeps its velocity — visibly so, and by a factor rather than a
 rounding.
*>
fn void a_spring_that_keeps_its_velocity_arrives_sooner() @test
{
	@with_gpu_js(; three::JsRuntime* run)
	{
		String value = @value(run, `
			const dt = 1 / 60;
			let kept = 0;
			const state = { velocity: 0 };
			for (let i = 0; i < 30; i++) kept = three.smoothDamp(kept, 100, state, 0.5, dt);

			let thrown = 0;
			for (let i = 0; i < 30; i++) thrown = three.smoothDamp(thrown, 100, { velocity: 0 }, 0.5, dt);

			return [kept > thrown, kept < 100, state.velocity > 0];
		`, "the spring script ran");

		test::@check(value == "[true,true,true]",
			"momentum gets there sooner, has not overshot, and is still moving; got %s", value);
	};
}

// ============================================================================
// Pointer lock
// ============================================================================

<*
 Pointer lock reports what the platform did, not what was asked for.

 A headless run has no window, so it reads false however it is set — and that is
 the contract rather than a limitation of the test: a script that needs a look
 either way reads the value back and falls back to a drag-look. Making this
 answer true would be the one shape that leaves a game silently unplayable on a
 platform where the lock is not implemented.
*>
fn void pointer_lock_reports_what_the_platform_did() @test
{
	@with_gpu_js(; three::JsRuntime* run)
	{
		String value = @value(run, `
			const before = three.input.pointerLock;
			three.input.pointerLock = true;
			const after = three.input.pointerLock;
			three.input.pointerLock = false;
			return [before, after, three.input.pointer.locked];
		`, "the pointer-lock script ran");

		test::@check(value == "[false,false,false]",
			"a run with no window never reports a lock; got %s", value);
	};
}

// ============================================================================
// The window
// ============================================================================

<*
 The window reports its absence rather than inventing a size.

 A headless run has no window, so the three numbers are zero and `resize` answers
 false — `pointerLock`'s contract in a second place, and for its reason: a game
 that sizes its own window should still start on a machine that has none.

 A bad size is the one thing here that does throw, and it throws headless too. No
 window is a fact about the machine; `resize(0, 900)` is a mistake in the script,
 and a platform that happens to have nothing to ask is no reason to swallow it.
*>
fn void the_window_reports_zero_when_there_is_none() @test
{
	@with_gpu_js(; three::JsRuntime* run)
	{
		String value = @value(run, `
			const before = [three.window.width, three.window.height, three.window.scale];
			const asked = three.window.resize(1600, 900);
			let refused = '';
			try { three.window.resize(0, 900); } catch (e) { refused = e.message.slice(0, 18); }
			return [before, asked, refused];
		`, "the window script ran");

		test::@check(value == `[[0,0,0],false,"three.window.resiz"]`,
			"a run with no window has no size and refuses a bad one; got %s", value);
	};
}

<*
 A locked cursor's movement is the platform's delta, not a difference of
 positions.

 `MouseTracker` is where that choice is made, and it is testable without a
 window: two readings at the *same* place, one locked and carrying a raw delta.
 The unlocked one reports no movement, because the cursor did not move; the
 locked one reports the hand's.
*>
fn void a_locked_cursor_reports_the_hand_and_not_the_cursor() @test
{
	three::MouseTracker tracker;
	three::WindowView view = { .width = 800, .height = 600, .scale = 1.0f, .image_width = 800, .image_height = 600 };

	// Settle the tracker on a position, so the next reading has something to
	// difference against.
	tracker.step(view.cursor({ 400, 300 }, false), 0);

	// The cursor has not moved and the hand has: the recentred, hidden case.
	three::Cursor locked = view.cursor({ 400, 300 }, false, raw: { 12, 5 }, locked: true);
	three::MouseState moved = tracker.step(locked, 16);

	test::@check(moved.locked, "the state carries the flag");
	test::@check(math::abs(moved.dx - 12.0f) < 1e-3f, "dx is the raw delta, got %f", moved.dx);
	// The window counts up and the image counts down, so the sign flips once.
	test::@check(math::abs(moved.dy + 5.0f) < 1e-3f, "dy is the raw delta, flipped, got %f", moved.dy);

	// The same reading unlocked reports nothing, because the cursor is where it
	// was — which is exactly the failure a lock removes.
	three::MouseState still = tracker.step(view.cursor({ 400, 300 }, false, raw: { 12, 5 }), 32);
	test::@check(still.dx == 0.0f && still.dy == 0.0f, "unlocked, a still cursor is no movement");
	test::@check(!still.locked, "and says so");
}

<*
 The crowd form of the controller has to be the SAME controller.

 It is a second entry point into `move_capsule`, and the failure that would
 matter is not a crash: it is a bulk form that quietly disagrees with the single
 one about a ledge or a slope, so a pack walks through a step the player has to
 climb. So the test is an exact comparison rather than a plausibility check —
 twelve agents over a floor, a wall and a ledge, stepped both ways, and every
 position has to match to the last bit.
*>
fn void the_crowd_controller_answers_what_the_single_one_does() @test
{
	@with_gpu_js(; three::JsRuntime* run)
	{
		String value = @value(run, `
			const scene = new three.Scene();
			const floor = new three.Mesh(new three.BoxGeometry(80, 2, 80));
			floor.position.y = -1;
			scene.add(floor);
			const wall = new three.Mesh(new three.BoxGeometry(20, 4, 1));
			wall.position.set(0, 2, 6);
			scene.add(wall);
			// Low enough to be climbed, which is what makes 'stepped' fire.
			const ledge = new three.Mesh(new three.BoxGeometry(20, 0.3, 4));
			ledge.position.set(0, 0.15, -6);
			scene.add(ledge);

			const N = 12, R = 0.4, HEIGHT = 1.2, HALF = HEIGHT / 2;
			const OPT = { radius: R, height: HEIGHT, step: 0.45, slope: 50, skin: 0.02, snap: 0.35 };

			const start = new Float32Array(N * 3);
			const motion = new Float32Array(N * 3);
			for (let i = 0; i < N; i++) {
				start[i * 3] = -8 + i * 1.5;
				start[i * 3 + 1] = HALF + 0.05;
				// Into the wall, over the ledge, and across open ground.
				start[i * 3 + 2] = i < 4 ? 4.5 : (i < 8 ? -3 : 0);
				motion[i * 3] = 0.05;
				motion[i * 3 + 1] = -0.08;
				motion[i * 3 + 2] = i < 4 ? 0.9 : (i < 8 ? -1.2 : 0.2);
			}

			const single = [], grounded = [], stepped = [];
			for (let i = 0; i < N; i++) {
				const r = three.moveAndSlide(
					[start[i * 3], start[i * 3 + 1], start[i * 3 + 2]],
					[motion[i * 3], motion[i * 3 + 1], motion[i * 3 + 2]], OPT);
				single.push(r.position.x, r.position.y, r.position.z);
				grounded.push(r.grounded);
				stepped.push(r.stepped);
			}

			const bulk = start.slice();
			const out = three.moveBuffer(N);
			const count = three.moveAndSlideAll(bulk, motion, { ...OPT, results: out });

			let worst = 0, flags = 0;
			for (let i = 0; i < N; i++) {
				for (let k = 0; k < 3; k++) worst = Math.max(worst, Math.abs(bulk[i * 3 + k] - single[i * 3 + k]));
				const f = out[i * 8 + 7] | 0;
				if (((f & three.moveResult.GROUNDED) !== 0) !== grounded[i]) flags++;
				if (((f & three.moveResult.STEPPED) !== 0) !== stepped[i]) flags++;
			}
			// The fixture has to actually reach the branches, or matching is free.
			return [count, worst, flags, grounded.filter(Boolean).length, stepped.filter(Boolean).length];
		`, "the crowd controller script ran");

		// Twelve stepped, not one bit of difference, no flag disagreement, all
		// twelve grounded and four of them having climbed the ledge.
		test::@check(value == "[12,0,0,12,4]",
			"the crowd form and the single form agree exactly; got %s", value);
	};
}

<*
 The `self` column, which is what the crowd form has instead of `ignore`.

 A character is a Group of meshes and it collides with its own chest without
 this — the same defect §17 fixed for the single form, arriving again at the
 place where "ignore this one object" cannot be written because there are two
 hundred of them.
*>
fn void every_agent_ignores_its_own_subtree() @test
{
	@with_gpu_js(; three::JsRuntime* run)
	{
		String value = @value(run, `
			const scene = new three.Scene();
			const floor = new three.Mesh(new three.BoxGeometry(60, 2, 60));
			floor.position.y = -1;
			scene.add(floor);

			const N = 6, R = 0.4, HEIGHT = 1.2;
			const bodies = [];
			for (let i = 0; i < N; i++) {
				const g = new three.Group();
				// A snout, in FRONT of the capsule rather than around it: a mesh
				// the capsule is already inside is depenetrated out and then
				// walks freely, which would pass this test for the wrong reason.
				const snout = new three.Mesh(new three.BoxGeometry(0.6, 0.8, 0.6));
				snout.position.set(1, 0.6, 0);
				g.add(snout);
				g.position.set(i * 6, 0, 0);
				scene.add(g);
				bodies.push(g);
			}

			const OPT = { radius: R, height: HEIGHT, step: 0.4, slope: 50, snap: 0.3 };
			const start = new Float32Array(N * 3);
			const motion = new Float32Array(N * 3);
			for (let i = 0; i < N; i++) {
				start[i * 3] = i * 6;
				start[i * 3 + 1] = HEIGHT / 2;
				motion[i * 3] = 1.5;
			}

			const stuck = start.slice();
			three.moveAndSlideAll(stuck, motion, OPT);

			const free = start.slice();
			three.moveAndSlideAll(free, motion, { ...OPT, self: three.batch(bodies).handles });

			// An array of objects has to mean the same thing as the column.
			const alsoFree = start.slice();
			three.moveAndSlideAll(alsoFree, motion, { ...OPT, self: bodies });

			let blocked = 0, moved = 0, agrees = 0;
			for (let i = 0; i < N; i++) {
				if (stuck[i * 3] - start[i * 3] < 0.5) blocked++;
				if (free[i * 3] - start[i * 3] > 1.49) moved++;
				if (Math.abs(free[i * 3] - alsoFree[i * 3]) < 1e-6) agrees++;
			}
			return [blocked, moved, agrees];
		`, "the self-column script ran");

		// Every one of them stopped on its own snout, every one of them walked
		// the whole metre and a half once told about itself, and the two
		// spellings of `self` agree.
		test::@check(value == "[6,6,6]",
			"an agent walks through itself and nothing else; got %s", value);
	};
}

<*
 The bulk field sampler against the single one, and the sentinel that differs.

 `field.cost` answers `Infinity` for unreachable and `field.sample` answers a
 negative number, which is the one place in this API where the convenient form
 and the flat form disagree about a value rather than about a shape. It is
 deliberate — converting means a JavaScript pass over the array, which is the
 loop being avoided — and a test is what keeps it deliberate.
*>
fn void the_bulk_sampler_agrees_with_the_single_field() @test
{
	@with_gpu_js(; three::JsRuntime* run)
	{
		String value = @value(run, `
			const scene = new three.Scene();
			const floor = new three.Mesh(new three.BoxGeometry(30, 1, 30));
			floor.position.y = -0.5;
			scene.add(floor);
			// An island nothing can walk to, so there is an unreachable sample.
			const island = new three.Mesh(new three.BoxGeometry(4, 1, 4));
			island.position.set(0, 8, 0);
			scene.add(island);

			three.nav.bake({ cell: 0.6, radius: 0.35, height: 1.2 });
			const field = three.nav.field([[-10, 0.2, -10]]);

			const points = [[-8, 0.2, -8], [0, 0.2, 0], [6, 0.2, 6], [0, 8.7, 0], [0, 40, 0]];
			const pos = new Float32Array(points.length * 3);
			points.forEach((p, i) => { pos[i * 3] = p[0]; pos[i * 3 + 1] = p[1]; pos[i * 3 + 2] = p[2]; });

			const costs = new Float32Array(points.length);
			const dirs = new Float32Array(points.length * 3);
			const count = field.sample(pos, { costs, directions: dirs });

			let costAgrees = 0, dirAgrees = 0, unreachable = 0, infinite = 0;
			points.forEach((p, i) => {
				const one = field.cost(p);
				const many = costs[i] < 0 ? Infinity : costs[i];
				if (one === Infinity) infinite++;
				if (costs[i] < 0) unreachable++;
				if ((one === Infinity && many === Infinity) || Math.abs(one - many) < 1e-4) costAgrees++;
				const d = field.direction(p);
				if (Math.abs(d.x - dirs[i * 3]) < 1e-6 && Math.abs(d.z - dirs[i * 3 + 2]) < 1e-6) dirAgrees++;
			});

			// Costs alone is allowed, and a disposed field answers rather than reads.
			const only = new Float32Array(points.length);
			const alone = field.sample(pos, { costs: only });
			field.dispose();
			const dead = new Float32Array(points.length);
			field.sample(pos, { costs: dead });

			return [count, costAgrees, dirAgrees, unreachable, infinite === unreachable, alone, dead[0] < 0];
		`, "the bulk sampler script ran");

		// Five sampled, five costs and five directions matching, TWO points off
		// the field — the island the floor cannot reach and the one in thin air
		// — the two sentinels naming the same set of points, and a disposed
		// field reporting everything unreachable.
		test::@check(value == "[5,5,5,2,true,5,true]",
			"the flat sampler is the same field; got %s", value);
	};
}

<*
 The Euler batch, and the trap that comes with any batch.

 Two things at once, because they are the same mistake seen from two sides: the
 nine-float form has to write the angles a script typed, and the object it wrote
 them past has to be brought back into agreement before anything writes that
 object by hand — or the next `position.y = ` sends all nine of the object's
 stale numbers and undoes the whole flush.
*>
fn void an_euler_batch_writes_angles_and_leaves_the_object_behind() @test
{
	@with_gpu_js(; three::JsRuntime* run)
	{
		String value = @value(run, `
			const scene = new three.Scene();
			const g = new three.Group();
			const arm = new three.Mesh(new three.BoxGeometry(0.2, 1, 0.2));
			arm.position.set(0, 0.5, 0);
			g.add(arm);
			scene.add(g);

			// Made and flushed unchanged, an Euler batch changes nothing —
			// which is only true because it is seeded from the object.
			g.rotation.set ? 0 : 0;
			g.rotation.z = Math.PI / 2;
			g.scale.set(1, 3, 1);
			const before = g.boundingBox();
			const seeded = three.batch([g], { euler: true });
			seeded.flush();
			const after = g.boundingBox();
			const unchanged = Math.abs(before.size.x - after.size.x) < 1e-4
				&& Math.abs(before.size.y - after.size.y) < 1e-4;

			// Now write through it. One flush, one crossing, two nodes.
			const batch = three.batch([g, arm], { euler: true });
			batch.positions[0] = 5;
			batch.positions[batch.rotationAt(0) + 2] = 0;      // undo the roll
			batch.positions[batch.scaleAt(0) + 1] = 1;
			batch.positions[batch.rotationAt(1)] = 1.0;        // the arm's own pitch
			const landed = batch.flush();

			// The node moved; the OBJECT has not, and that is the trap.
			const nodeMoved = Math.abs(g.boundingBox().center.x - 5) < 0.6;
			const objectStale = g.position.x === 0;

			const synced = batch.sync();
			const objectAgrees = g.position.x === 5
				&& Math.abs(g.rotation.z) < 1e-6
				&& Math.abs(arm.rotation.x - 1.0) < 1e-6
				&& g.scale.y === 1;

			// And after sync an ordinary write no longer undoes the batch.
			g.position.y = 2;
			const survived = Math.abs(arm.rotation.x - 1.0) < 1e-6 && g.scale.y === 1;

			let refused = false;
			try { three.batch([g], { trs: true, euler: true }); } catch (e) { refused = e instanceof RangeError; }

			return [batch.stride, landed, synced, unchanged, nodeMoved, objectStale, objectAgrees, survived, refused];
		`, "the euler batch script ran");

		test::@check(value == "[9,2,2,true,true,true,true,true,true]",
			"nine floats, written, and the object caught up; got %s", value);
	};
}
