<*
 Bounds, and the placement they exist to make possible.

	`c3c test --trust=full --test-noleak --test-filter three_tests::bounds`

 **The question this suite answers:** a script has a kit piece and a wall, and
 wants the piece's back face flush with the wall. Before M6 the only way to say
 that was to carry the piece's size into the script as a literal, because
 nothing in the API would tell you how big anything was. A table of literals is
 wrong the moment the asset is re-exported, and it fails *quietly* — the piece
 still draws, it just sinks into the masonry.

 The check that matters most here is `the_two_boxes_agree_at_the_root`, and it is
 not about bounds at all: `boundsInParent` composes a rotation in JavaScript and
 `boundingBox` composes it in C3, so if the two ever disagree about what
 `rotation.y = 0.7` means, one of them is wrong and placement is wrong with it.
 It is the only check here that could catch that, because every other one uses
 an axis-aligned object where every Euler convention agrees.
*>
module three_tests::bounds;

import three;
import vk;
import std::core::test;

<*
 A runtime with a headless device.

 Every check here needs one, which is worth saying because none of them draws:
 `three.load` and `new three.BoxGeometry(...)` both refuse without a device even
 though neither uploads anything yet, so a bounds suite that only ever measures
 still cannot use the deviceless harness `js_test.c3` opens with.
*>
macro @with_js(; @body(three::JsRuntime* run))
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

// ============================================================================
// A shape knows its own size
// ============================================================================

fn void a_generated_shape_carries_its_own_box() @test
{
	@with_js(; three::JsRuntime* run)
	{
		three::RunResult result = run.run(`
			const g = new three.BoxGeometry(2, 3, 4);
			const b = g.bounds;
			return [b.size.x, b.size.y, b.size.z, b.center.x, b.center.y, b.center.z];
		`);
		defer result.free();

		test::@check(result.ok, "the script succeeded: %s", result.error);
		test::@check(result.value == "[2,3,4,0,0,0]", "a 2x3x4 box is 2x3x4 about the origin, got '%s'", result.value);
	};
}

<*
 The box is what the shape *is*, not what it was asked for.

 A torus is `2 * (radius + tube)` across and `2 * tube` thick, and neither number
 is an argument to the constructor. This is exactly the case where a script
 guessing from `parameters` guesses wrong.
*>
fn void a_torus_is_wider_than_the_radius_it_was_given() @test
{
	@with_js(; three::JsRuntime* run)
	{
		three::RunResult result = run.run(`
			const b = new three.TorusGeometry(1, 0.4).bounds;
			const across = b.size.x, thick = b.size.z;
			return { across: Math.round(across * 1000) / 1000, thick: Math.round(thick * 1000) / 1000 };
		`);
		defer result.free();

		test::@check(result.ok, "the script succeeded: %s", result.error);
		test::@check(
			result.value.contains(`"across":2.8`),
			"2 * (1 + 0.4) across, got '%s'", result.value
		);
		test::@check(result.value.contains(`"thick":0.8`), "2 * 0.4 thick, got '%s'", result.value);
	};
}

// ============================================================================
// The two boxes, and the rotation they must agree about
// ============================================================================

<*
 `boundsInParent` builds `Rx*Ry*Rz` in JavaScript; `boundingBox` asks the host,
 which composes the same rotation as a quaternion in C3. For an object parented
 to the scene root the two frames are the same frame, so the two boxes must be
 the same box — and a rotation with all three angles non-zero and a non-uniform
 scale is what makes every wrong convention produce a different answer.

 If this fails, `align` misplaces every rotated piece and does it quietly.
*>
fn void the_two_boxes_agree_at_the_root() @test
{
	@with_js(; three::JsRuntime* run)
	{
		three::RunResult result = run.run(`
			const scene = new three.Scene();
			const m = new three.Mesh(new three.BoxGeometry(2, 3, 4));
			m.rotation.set(0.3, 0.7, -0.4);
			m.scale.set(1.5, 0.8, 2.0);
			m.position.set(5, -2, 3);
			scene.add(m);

			const local = m.boundsInParent();
			const world = m.boundingBox();
			let worst = 0;
			for (const k of ['x', 'y', 'z']) {
				worst = Math.max(worst,
					Math.abs(local.min[k] - world.min[k]),
					Math.abs(local.max[k] - world.max[k]));
			}
			return { agree: worst < 1e-4, worst };
		`);
		defer result.free();

		test::@check(result.ok, "the script succeeded: %s", result.error);
		test::@check(result.value.contains(`"agree":true`),
			"the JS rotation and the host rotation are the same rotation, got '%s'", result.value);
	};
}

<*
 A group has no geometry of its own, so its box is its children's — and its own
 transform applies on top. Without this a script cannot ask how big a building
 it just assembled is.
*>
fn void a_group_is_boxed_by_what_is_under_it() @test
{
	@with_js(; three::JsRuntime* run)
	{
		three::RunResult result = run.run(`
			const g = new three.Group();
			const a = new three.Mesh(new three.BoxGeometry(2, 2, 2));
			a.position.set(-3, 0, 0);
			const b = new three.Mesh(new three.BoxGeometry(2, 2, 2));
			b.position.set(3, 0, 0);
			g.add(a); g.add(b);
			const box = g.boundsInParent();
			return [box.min.x, box.max.x, box.size.y];
		`);
		defer result.free();

		test::@check(result.ok, "the script succeeded: %s", result.error);
		test::@check(result.value == "[-4,4,2]", "-4..4 wide and 2 tall, got '%s'", result.value);
	};
}

fn void an_empty_group_has_no_box_rather_than_a_zero_one() @test
{
	@with_js(; three::JsRuntime* run)
	{
		three::RunResult result = run.run(`return new three.Group().boundsInParent();`);
		defer result.free();

		test::@check(result.ok, "the script succeeded: %s", result.error);
		test::@check(result.value == "null", "nothing to measure is null, got '%s'", result.value);
	};
}

// ============================================================================
// Placing
// ============================================================================

fn void align_puts_the_face_where_it_was_asked_for() @test
{
	@with_js(; three::JsRuntime* run)
	{
		three::RunResult result = run.run(`
			const m = new three.Mesh(new three.BoxGeometry(2, 3, 4));
			m.align('y', 'min', 0);          // stand it on the ground
			m.align('z', 'max', 10);         // front face at z = 10
			const b = m.boundsInParent();
			return [b.min.y, b.max.z, m.position.y, m.position.z];
		`);
		defer result.free();

		test::@check(result.ok, "the script succeeded: %s", result.error);
		test::@check(result.value == "[0,10,1.5,8]",
			"base at 0 and front at 10, from a centred pivot, got '%s'", result.value);
	};
}

<*
 The scale is an input to where the box is, not something `align` has to be told
 about. A piece scaled to fit a floor height still lands on the floor.
*>
fn void align_respects_a_scale_set_before_it() @test
{
	@with_js(; three::JsRuntime* run)
	{
		three::RunResult result = run.run(`
			const m = new three.Mesh(new three.BoxGeometry(1, 1, 1));
			m.scale.set(1, 6, 1);
			m.align('y', 'min', 2);
			return [m.position.y, m.boundsInParent().min.y, m.boundsInParent().max.y];
		`);
		defer result.free();

		test::@check(result.ok, "the script succeeded: %s", result.error);
		test::@check(result.value == "[5,2,8]", "a 6-tall box standing at y=2, got '%s'", result.value);
	};
}

fn void align_to_places_one_sibling_against_another() @test
{
	@with_js(; three::JsRuntime* run)
	{
		three::RunResult result = run.run(`
			const room = new three.Group();
			const wall = new three.Mesh(new three.BoxGeometry(10, 8, 0.5));
			const shelf = new three.Mesh(new three.BoxGeometry(2, 0.2, 1));
			room.add(wall); room.add(shelf);
			// shelf's back face against the wall's front face, 0.05 proud
			shelf.alignTo(wall, { axis: 'z', mine: 'min', theirs: 'max', offset: -0.05 });
			const r = v => Math.round(v * 1e6) / 1e6;
			return [r(shelf.boundsInParent().min.z), r(wall.boundsInParent().max.z)];
		`);
		defer result.free();

		test::@check(result.ok, "the script succeeded: %s", result.error);
		test::@check(result.value == "[0.2,0.25]", "back face 0.05 inside the wall face, got '%s'", result.value);
	};
}

<*
 Two parents are two frames, and a box measured in one means nothing in the
 other. Refused with a sentence naming the alternative rather than answered with
 a number that is wrong by whatever the parents differ by.
*>
fn void align_to_refuses_objects_that_are_not_siblings() @test
{
	@with_js(; three::JsRuntime* run)
	{
		three::RunResult result = run.run(`
			const a = new three.Group();
			const m = new three.Mesh(new three.BoxGeometry(1, 1, 1));
			const other = new three.Mesh(new three.BoxGeometry(1, 1, 1));
			a.add(m);
			try { m.alignTo(other, { axis: 'y' }); return 'no throw'; }
			catch (e) { return e.message; }
		`);
		defer result.free();

		test::@check(result.ok, "the script succeeded: %s", result.error);
		test::@check(result.value.contains("share a parent"), "it says why, got '%s'", result.value);
	};
}

fn void align_needs_something_to_measure() @test
{
	@with_js(; three::JsRuntime* run)
	{
		three::RunResult result = run.run(`
			try { new three.Group().align('y', 'min', 0); return 'no throw'; }
			catch (e) { return e.message; }
		`);
		defer result.free();

		test::@check(result.value.contains("draws nothing"), "it says what is missing, got '%s'", result.value);
	};
}

fn void a_bad_axis_is_refused_by_name() @test
{
	@with_js(; three::JsRuntime* run)
	{
		three::RunResult result = run.run(`
			const m = new three.Mesh(new three.BoxGeometry(1, 1, 1));
			try { m.align('w', 'min', 0); return 'no throw'; }
			catch (e) { return e.message; }
		`);
		defer result.free();

		test::@check(result.value.contains(`not \"w\"`), "the bad axis is quoted back, got '%s'", result.value);
		test::@check(result.value.contains("'x', 'y' or 'z'"), "and the good ones are listed, got '%s'", result.value);
	};
}

// ============================================================================
// Placing a kit: several axes at once, a run, and another frame
// ============================================================================

<*
 One call for a whole placement, because a placement is not one axis.

 "My back face on your front face, centred on you in x" is the sentence, and it
 used to be two `alignTo` calls that each re-measured the hall. The axis nobody
 named is the assertion that matters as much as the two that were: the lean-to
 was standing at y = 5 before the call and is standing at y = 5 after it.
*>
fn void align_to_says_a_whole_placement_in_one_call() @test
{
	@with_js(; three::JsRuntime* run)
	{
		three::RunResult result = run.run(`
			const room = new three.Group();
			const hall = new three.Mesh(new three.BoxGeometry(6, 4, 6));
			const lean = new three.Mesh(new three.BoxGeometry(2, 2, 3));
			room.add(hall, lean);
			lean.position.set(7, 5, 9);
			lean.alignTo(hall, { z: { mine: 'min', theirs: 'max' }, x: 'center' });
			const a = lean.boundsInParent(), b = hall.boundsInParent();
			const r = v => Math.round(v * 1e6) / 1e6;
			return { back: r(a.min.z - b.max.z), across: r(a.center.x - b.center.x), y: lean.position.y };
		`);
		defer result.free();

		test::@check(result.ok, "the script succeeded: %s", result.error);
		test::@check(result.value.contains(`"back":0`),
			"the lean-to's back face should be on the hall's front face, got '%s'", result.value);
		test::@check(result.value.contains(`"across":0`),
			"and it should be centred on the hall in x, got '%s'", result.value);
		test::@check(result.value.contains(`"y":5`),
			"y was not named, so it must not have moved: %s", result.value);
	};
}

<*
 A misspelt option is refused by name rather than quietly doing the default.

 `{ axes: 'xz' }` would otherwise align y, min against max, and answer that it
 had done what it was asked — which is the failure mode the whole measuring API
 exists to remove.
*>
fn void an_option_align_to_does_not_have_is_refused_by_name() @test
{
	@with_js(; three::JsRuntime* run)
	{
		three::RunResult result = run.run(`
			const room = new three.Group();
			const a = new three.Mesh(new three.BoxGeometry(1, 1, 1));
			const b = new three.Mesh(new three.BoxGeometry(1, 1, 1));
			room.add(a, b);
			try { a.alignTo(b, { axes: 'xz' }); return 'no throw'; }
			catch (e) { return e.message; }
		`);
		defer result.free();

		test::@check(result.ok, "the script succeeded: %s", result.error);
		test::@check(result.value.contains("axes"), "the bad key is quoted back, got '%s'", result.value);
		test::@check(result.value.contains("mine, theirs"), "and the good ones are listed, got '%s'", result.value);
	};
}

<*
 A run steps by each piece, not by one constant.

 The three panels are 1, 2 and 0.5 wide, which is the case a script's own loop
 gets wrong the moment a kit gains a piece of a different size: a single measured
 step lays the second panel over the first and the third in mid-air.
*>
fn void a_run_steps_by_each_piece_rather_than_by_a_constant() @test
{
	@with_js(; three::JsRuntime* run)
	{
		three::RunResult result = run.run(`
			const wall = new three.Group();
			const panels = [1, 2, 0.5].map(w => new three.Mesh(new three.BoxGeometry(w, 2, 0.3)));
			wall.row('x', panels, { at: 0 });
			const r = v => Math.round(v * 1e6) / 1e6;
			return panels.map(p => [r(p.boundsInParent().min.x), r(p.boundsInParent().max.x)]);
		`);
		defer result.free();

		test::@check(result.ok, "the script succeeded: %s", result.error);
		test::@check(result.value == "[[0,1],[1,3],[3,3.5]]",
			"three panels of different widths, edge to edge from 0, got '%s'", result.value);
	};
}

<*
 A quarter-turned piece steps by the side it now presents.

 A 4 x 1 panel turned about y is 1 across, and a run that assumed the piece's
 width would leave three units of daylight in the wall. `boundsInParent()` has
 the rotation in it, which is why the run measures rather than asks the piece
 how wide it was authored.
*>
fn void a_run_steps_by_the_side_a_turned_piece_presents() @test
{
	@with_js(; three::JsRuntime* run)
	{
		three::RunResult result = run.run(`
			const wall = new three.Group();
			const panels = [0, 1, 0].map(turns => {
				const p = new three.Mesh(new three.BoxGeometry(4, 2, 1));
				if (turns) p.rotation.y = turns * Math.PI / 2;
				return p;
			});
			wall.row('x', panels, { at: 0 });
			const r = v => Math.round(v * 1e6) / 1e6;
			return panels.map(p => r(p.boundsInParent().max.x));
		`);
		defer result.free();

		test::@check(result.ok, "the script succeeded: %s", result.error);
		test::@check(result.value == "[4,5,9]",
			"the turned panel should have stepped by 1 and not by 4, got '%s'", result.value);
	};
}

<*
 `gap` is the measured step plus a constant, and a negative one laps the pieces
 over each other — which is what a course of roof tiles is.
*>
fn void a_run_takes_the_gap_or_the_overlap_it_is_asked_for() @test
{
	@with_js(; three::JsRuntime* run)
	{
		three::RunResult result = run.run(`
			const r = v => Math.round(v * 1e6) / 1e6;
			const run = (gap) => {
				const g = new three.Group();
				const p = [0, 1].map(() => new three.Mesh(new three.BoxGeometry(1, 1, 1)));
				g.row('x', p, { at: 0, gap });
				return r(p[1].boundsInParent().min.x);
			};
			return [run(0), run(0.25), run(-0.4)];
		`);
		defer result.free();

		test::@check(result.ok, "the script succeeded: %s", result.error);
		test::@check(result.value == "[1,1.25,0.6]",
			"butted, spaced and lapped, got '%s'", result.value);
	};
}

<*
 A run with no start follows the piece that is already standing there, and it
 adopts the pieces it was handed.

 Both halves of the loop it replaces: a script that has placed the corner and
 wants the rest of the wall after it should not have to say where the corner was,
 and should not have to `add` in a second pass.
*>
fn void a_run_with_no_start_follows_the_piece_already_there() @test
{
	@with_js(; three::JsRuntime* run)
	{
		three::RunResult result = run.run(`
			const wall = new three.Group();
			const panels = [0, 1, 2].map(() => new three.Mesh(new three.BoxGeometry(2, 2, 0.3)));
			panels[0].align('x', 'min', 10);
			wall.row('x', panels);
			const r = v => Math.round(v * 1e6) / 1e6;
			return {
				at: panels.map(p => r(p.boundsInParent().min.x)),
				adopted: wall.children.length,
			};
		`);
		defer result.free();

		test::@check(result.ok, "the script succeeded: %s", result.error);
		test::@check(result.value.contains("[10,12,14]"),
			"the run should have started where the first panel already was, got '%s'", result.value);
		test::@check(result.value.contains(`"adopted":3`),
			"and the pieces should have been added, got '%s'", result.value);
	};
}

<*
 Across two frames, in world space, which is what the sibling form refuses.

 A lean-to in one group against a hall in another — the arrangement `houses.js`
 builds by hand. Both boxes come from the host, so the check is on world faces:
 the lean-to's back is on the hall's front and the two are centred on each other
 in x, whatever the groups' own offsets were.
*>
fn void align_to_reaches_into_another_frame_in_world_space() @test
{
	@with_js(; three::JsRuntime* run)
	{
		three::RunResult result = run.run(`
			const scene = new three.Scene();
			const east = new three.Group(); east.position.set(6, 0, -2); scene.add(east);
			const hall = new three.Mesh(new three.BoxGeometry(6, 4, 6)); east.add(hall);
			const yard = new three.Group(); yard.position.set(-4, 0, 5); scene.add(yard);
			const lean = new three.Mesh(new three.BoxGeometry(2, 2, 3)); yard.add(lean);

			lean.alignTo(hall, { world: true, z: { mine: 'min', theirs: 'max' }, x: 'center' });
			const a = lean.boundingBox(), b = hall.boundingBox();
			// Four places, not six: a world box comes back through the host as
			// f32, so the last of six digits is the device's noise floor.
			const r = v => Math.round(v * 1e4) / 1e4;
			return { back: r(a.min.z - b.max.z), across: r(a.center.x - b.center.x), y: r(a.center.y) };
		`);
		defer result.free();

		test::@check(result.ok, "the script succeeded: %s", result.error);
		test::@check(result.value.contains(`"back":0`),
			"the lean-to's world back face should be on the hall's world front face, got '%s'", result.value);
		test::@check(result.value.contains(`"across":0`),
			"and centred on it in world x, got '%s'", result.value);
		test::@check(result.value.contains(`"y":0`),
			"y was not named, so nothing should have moved in it: %s", result.value);
	};
}

<*
 **The two frames that are not a translation, which is where this could be
 quietly wrong.**

 The mover hangs under a group turned 0.4 radians — not a quarter turn, so an
 axis-aligned world box is not axis-aligned in its parent — and scaled 2 x 1 x
 0.5, which is not uniform either. A box carried into the parent's frame and
 aligned there would land somewhere near and not on; converting the *step*
 instead is exact, because a translation goes through any invertible frame
 exactly. The faces have to meet to a millionth.

 It is also the check that the ancestor chain is composed in the order the host
 composes it: with the rotation applied on the wrong side, the piece moves off
 along a different diagonal and the gap is metres.
*>
fn void a_world_align_is_exact_under_a_turned_and_squashed_ancestor() @test
{
	@with_js(; three::JsRuntime* run)
	{
		three::RunResult result = run.run(`
			const scene = new three.Scene();
			const east = new three.Group(); east.position.set(6, 0, -2); scene.add(east);
			const hall = new three.Mesh(new three.BoxGeometry(6, 4, 6)); east.add(hall);

			const yard = new three.Group();
			yard.position.set(-4, 1, 5);
			yard.rotation.y = 0.4;
			yard.scale.set(2, 1, 0.5);
			scene.add(yard);
			const lean = new three.Mesh(new three.BoxGeometry(2, 2, 3)); yard.add(lean);

			lean.alignTo(hall, { world: true, z: { mine: 'min', theirs: 'max' }, x: 'center' });
			const a = lean.boundingBox(), b = hall.boundingBox();
			// Four places, not six: a world box comes back through the host as
			// f32, so the last of six digits is the device's noise floor.
			const r = v => Math.round(v * 1e4) / 1e4;
			return { back: r(a.min.z - b.max.z), across: r(a.center.x - b.center.x), y: r(a.center.y) };
		`);
		defer result.free();

		test::@check(result.ok, "the script succeeded: %s", result.error);
		test::@check(result.value.contains(`"back":0`),
			"a turned, non-uniformly scaled frame should still land the face exactly, got '%s'", result.value);
		test::@check(result.value.contains(`"across":0`),
			"and centre it exactly in world x, got '%s'", result.value);
		test::@check(result.value.contains(`"y":1`),
			"y was not named, so the piece should still ride at its parent's height: %s", result.value);
	};
}

<*
 Two objects that share a parent after all are allowed, not refused, and where
 nothing above them turns or squashes the frame they get the sibling answer.

 The shelf is aligned the sibling way, knocked off the wall, and aligned again
 the world way. The same number twice is what says the world path is the same
 move and not a second convention.
*>
fn void a_world_align_between_siblings_is_the_sibling_answer() @test
{
	@with_js(; three::JsRuntime* run)
	{
		three::RunResult result = run.run(`
			const scene = new three.Scene();
			const room = new three.Group(); room.position.set(3, 0, -1); scene.add(room);
			const wall = new three.Mesh(new three.BoxGeometry(10, 8, 0.5));
			const shelf = new three.Mesh(new three.BoxGeometry(2, 0.2, 1));
			room.add(wall, shelf);

			const opts = { axis: 'z', mine: 'min', theirs: 'max', offset: -0.05 };
			shelf.alignTo(wall, opts);
			const sibling = shelf.position.z;
			shelf.position.z = 9;
			shelf.alignTo(wall, { ...opts, world: true });
			const r = v => Math.round(v * 1e6) / 1e6;
			return [r(sibling), r(shelf.position.z)];
		`);
		defer result.free();

		test::@check(result.ok, "the script succeeded: %s", result.error);
		test::@check(result.value == "[0.7,0.7]",
			"the two forms should agree in a frame that only translates, got '%s'", result.value);
	};
}

<*
 The refusal names the door beside it rather than sending the caller back to
 arithmetic. The old sentence said "measure with boundsInParent() and place with
 align" — which is the loop the verbs exist to delete.
*>
fn void align_to_points_at_the_world_form_when_the_parents_differ() @test
{
	@with_js(; three::JsRuntime* run)
	{
		three::RunResult result = run.run(`
			const a = new three.Group();
			const m = new three.Mesh(new three.BoxGeometry(1, 1, 1));
			const other = new three.Mesh(new three.BoxGeometry(1, 1, 1));
			a.add(m);
			try { m.alignTo(other, { axis: 'y' }); return 'no throw'; }
			catch (e) { return e.message; }
		`);
		defer result.free();

		test::@check(result.ok, "the script succeeded: %s", result.error);
		test::@check(result.value.contains("world: true"),
			"the refusal should name the world form, got '%s'", result.value);
	};
}

<*
 A frame flattened to nothing on an axis is refused: no local move produces the
 world one, and answering with a division by zero would put the piece at NaN and
 keep it there.
*>
fn void a_frame_scaled_to_nothing_is_refused_rather_than_guessed() @test
{
	@with_js(; three::JsRuntime* run)
	{
		three::RunResult result = run.run(`
			const scene = new three.Scene();
			const hall = new three.Mesh(new three.BoxGeometry(6, 4, 6)); scene.add(hall);
			const flat = new three.Group(); flat.scale.set(1, 0, 1); scene.add(flat);
			const piece = new three.Mesh(new three.BoxGeometry(1, 1, 1)); flat.add(piece);
			try { piece.alignTo(hall, { world: true, axis: 'x' }); return 'no throw'; }
			catch (e) { return e.message; }
		`);
		defer result.free();

		test::@check(result.ok, "the script succeeded: %s", result.error);
		test::@check(result.value.contains("scaled to nothing"),
			"it says which way it is stuck, got '%s'", result.value);
	};
}

// ============================================================================
// Measuring a file
// ============================================================================

<*
 The whole point of reading bounds out of the JSON rather than off the device:
 asking how big a kit's pieces are is what a script does *before* deciding which
 twelve of two hundred to place, and it must not upload the other hundred and
 eighty-eight.
*>
fn void measuring_a_loaded_mesh_does_not_upload_it() @test
{
	@with_js(; three::JsRuntime* run)
	{
		three::RunResult result = run.run(`
			const a = three.load("test/fixtures/textured.glb");
			const b = a.meshAt(0).bounds;
			// Nothing has been added to a scene, so nothing should be resident.
			return { hasSize: b.size.x > 0 && b.size.y > 0, textures: three.stats().textures };
		`);
		defer result.free();

		test::@check(result.ok, "the script succeeded: %s", result.error);
		test::@check(result.value.contains(`"hasSize":true`), "the piece has a size, got '%s'", result.value);
		test::@check(result.value.contains(`"textures":0`),
			"and measuring it put nothing on the device, got '%s'", result.value);
	};
}

// ============================================================================
// Rotation, where the box used to lie
// ============================================================================

<*
 **The four-sided cone at 45 degrees, which is the case that started this.**

 `ConeGeometry(1, 1, 4)` is a square pyramid, and its base sits corner-on to the
 axes: the four base vertices are at (+-1, 0) and (0, +-1), so the untouched
 shape spans 2 on x and 2 on z. Turn it 45 degrees about y and the square becomes
 axis-aligned with a side of sqrt(2), so the honest half-extent is 0.707.

 Bounding the *box* instead of the vertices reports 1.414 — exactly double —
 because rotating an axis-aligned box by 45 degrees and re-bounding the result
 grows it by sqrt(2) on both axes, and that is right only for a shape that
 actually fills its box. A diamond does not.

 Rotate it 45 degrees the other way, or 135, or 225, and the answer is the same
 0.707 by symmetry, so the check sweeps them: a fix that special-cased one angle
 would pass the first and fail the rest.

 This is the shape and the angle every hip roof in `examples/village` is built
 from, which is why its church reported a spire 3 units longer than it is.
*>
fn void a_diamond_turned_45_degrees_is_not_bigger() @test
{
	@with_js(; three::JsRuntime* run)
	{
		three::RunResult result = run.run(`
			const scene = new three.Scene();
			const out = [];
			for (const turn of [0.25, 0.75, 1.25, -0.25]) {
				const m = new three.Mesh(new three.ConeGeometry(1, 1, 4));
				m.rotation.y = turn * Math.PI;
				scene.add(m);
				const b = m.boundingBox();
				out.push([b.max.x, b.max.z]);
				scene.remove(m);
			}
			return out;
		`);
		defer result.free();
		test::@check(result.ok, "the script succeeded: %s", result.error);

		// 0.7071 to four places, and nothing anywhere near 1.414.
		test::@check(!result.value.contains("1.41") && !result.value.contains("1.4142"),
			"a 45-degree turn is still doubling the box: %s", result.value);
		test::@check(result.value.contains("0.707"),
			"the turned pyramid should reach 0.707 on x and z, got %s", result.value);
	};
}

<*
 An axis-aligned rotation is unchanged, which is the half that says the fix did
 not simply shrink everything.

 A box at 90 degrees is the case where re-bounding the AABB was already exact, so
 the two methods have to agree here. If they do not, the vertex pass has a
 transform bug that the 45-degree check would happily hide — it only asserts a
 number got smaller.
*>
fn void a_right_angle_measures_the_same_as_it_always_did() @test
{
	@with_js(; three::JsRuntime* run)
	{
		three::RunResult result = run.run(`
			const scene = new three.Scene();
			const m = new three.Mesh(new three.BoxGeometry(4, 1, 2));
			m.rotation.y = Math.PI / 2;
			scene.add(m);
			const b = m.boundingBox();
			return { x: b.max.x, y: b.max.y, z: b.max.z };
		`);
		defer result.free();
		test::@check(result.ok, "the script succeeded: %s", result.error);

		// 4 x 1 x 2 turned a quarter turn about y is 2 x 1 x 4.
		test::@check(result.value.contains(`"x":1`), "half-extent x should be 1, got %s", result.value);
		test::@check(result.value.contains(`"y":0.5`), "half-extent y should be 0.5, got %s", result.value);
		test::@check(result.value.contains(`"z":2`), "half-extent z should be 2, got %s", result.value);
	};
}

<*
 `align` on a rotated shape puts the face where it was asked for.

 The point of fixing the box at all. `align('y', 'min', 0)` reads the box and
 subtracts, so a box that over-reports floats the piece by exactly the amount it
 over-reported — and `BoxHelper`, drawn to check, agrees with it, because it is
 the same number twice.

 A cone tipped about x rather than turned about y, so the error lands on the axis
 being aligned rather than beside it.
*>
fn void align_lands_a_tipped_shape_on_the_floor() @test
{
	@with_js(; three::JsRuntime* run)
	{
		three::RunResult result = run.run(`
			const scene = new three.Scene();
			const m = new three.Mesh(new three.ConeGeometry(1, 2, 4));
			m.rotation.x = Math.PI / 4;
			scene.add(m);
			m.align('y', 'min', 0);
			return { min: m.boundingBox().min.y };
		`);
		defer result.free();
		test::@check(result.ok, "the script succeeded: %s", result.error);
		test::@check(result.value.contains(`"min":0`),
			"align asked for a floor at 0 and the shape did not land on it: %s", result.value);
	};
}

<*
 Adding a glTF mesh to a scene is what keeps `boundingBox()` on the exact path.

 `world_mesh_bounds` falls back to re-bounding the local box when a mesh has no
 positions on the CPU, and the question worth pinning is whether a script can
 ever see that fallback. It cannot: `add()` retains the mesh, retaining uploads
 it, and `boundingBox()` refuses to answer for anything not in a scene. So the
 exact path is not an optimisation that sometimes applies — it is every case the
 API can be asked about.

 Asserted the only way that distinguishes it from wishful thinking: the mesh is
 resident *after the add and before any frame is drawn*. The lazy-loading
 invariant next door is untouched, because that one measures a mesh reference
 rather than a scene object.
*>
fn void adding_a_mesh_is_what_makes_its_box_exact() @test
{
	@with_js(; three::JsRuntime* run)
	{
		three::RunResult result = run.run(`
			const scene = new three.Scene();
			const a = three.load("test/fixtures/textured.glb");
			const before = three.stats().textures;
			const m = new three.Mesh(a.mesh("quad_left"));
			m.rotation.y = Math.PI / 4;
			scene.add(m);
			const b = m.boundingBox();
			return { before, after: three.stats().textures, sized: b.size.x > 0 };
		`);
		defer result.free();
		test::@check(result.ok, "the script succeeded: %s", result.error);
		test::@check(result.value.contains(`"before":0`),
			"loading alone should still upload nothing: %s", result.value);
		test::@check(result.value.contains(`"after":1`),
			"adding the mesh should have made it resident, which is what puts its vertices on the CPU: %s",
			result.value);
		test::@check(result.value.contains(`"sized":true`), "and it has a box: %s", result.value);
	};
}

<*
 A reference outliving its asset answers with a throw, not with the size the
 mesh used to be. Every other handle in this API revalidates on use, and a
 cached box would be the one that did not.
*>
fn void bounds_from_a_stale_reference_throw() @test
{
	@with_js(; three::JsRuntime* run)
	{
		three::RunResult result = run.run(`
			const a = three.load("test/fixtures/textured.glb");
			const ref = a.meshAt(0);
			ref.bounds;
			new three.Scene().unload();
			try { ref.bounds; return 'no throw'; }
			catch (e) { return 'threw'; }
		`);
		defer result.free();

		test::@check(result.ok, "the script succeeded: %s", result.error);
		test::@check(result.value == `"threw"`, "a stale reference throws, got '%s'", result.value);
	};
}
