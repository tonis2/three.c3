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
import qjs;
import std::core::test;
import std::io;
import std::math;

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
