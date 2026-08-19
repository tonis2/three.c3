<*
 Debug draw: the shapes a scene is looked at with rather than built out of.

	`c3c test --trust=full --test-noleak --test-filter three_tests::lines`

 **The question this suite answers:** a piece was placed and it is not where it
 should be, or two faces are 0.01 apart and the render is a starburst. Nothing in
 a solid picture says where a box ends, where a pivot is, or which triangles a
 mesh has — so the answer used to be a render, a zoom and a theory.

 The design under test is `scene/lines.c3`'s: a helper is an *ordinary mesh over
 an ordinary asset*, not an immediate-mode side channel. That claim is what most
 of the checks below are about, because it is the part that would be cheap to
 believe and expensive to be wrong about — every property a script depends on
 (one draw call for a thousand, `remove` works, `unloadUnused` gives the memory
 back, a click goes through) is a consequence of it rather than a feature.

 ## Two halves, and the split is where the risk is

 The C3 half counts vertices and indices, because those are the numbers a picture
 cannot check: a wireframe that drew every shared edge twice looks exactly like
 one that does not, and costs twice the index buffer.

 The JS half is about the *material*, and `a_helper_draws_with_the_line_material`
 is the one to keep. `prelude.js` spells the line material as the literal `1`,
 because there is no verb that answers it — so that number is two spellings of
 one constant, which is the drift that renders fine and is wrong. The check reads
 the material back off the host node and compares it against `three::LINE_MATERIAL`
 itself, which is the only way to make the literal a fact rather than a hope.
*>
module three_tests::lines;

import three;
import vk;
import qjs;
import std::core::test;
import std::io;
import std::math;

<*
 A runtime with a headless device.

 A device for the same reason `bounds_test.c3` needs one and for one more: a line
 shape is *uploaded* when it is asked for, exactly as a generated shape is, so
 there is nothing here that could run on the deviceless harness.
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

<*
 How many live nodes draw with a given material.

 The JS side has no way to ask — `_i` and `_g` are private and `mesh.material`
 answers with the ShaderMaterial or null, never with the host's index — so the
 check that a helper got the *right* index has to be made from here.
*>
fn uint nodes_with_material(three::JsRuntime* run, uint material)
{
	uint found = 0;
	foreach (&node : run.pass.scene.nodes)
	{
		if (node.alive && node.material == material) found++;
	}
	return found;
}

// ============================================================================
// The shapes themselves
// ============================================================================

<*
 Twelve edges, eight corners, and the same extent `BoxGeometry(1, 1, 1)` has.

 The extent is the half worth stating: a helper is placed by copying a box's
 centre into `position` and its size into `scale`, and that is only correct if
 the unit cube's corners are at +/- 0.5. At +/- 1 every helper would be twice the
 size of the thing it was drawn around, which reads as a placement bug in the
 caller rather than as a bug here.
*>
fn void the_unit_box_is_twelve_edges_across_one_unit() @test
{
	@with_js(; three::JsRuntime* run)
	{
		three::AssetId id = run.pass.assets.lines(&run.renderer.gpu, { .kind = three::LineKind.BOX })!!;
		three::GpuMesh* mesh = run.pass.assets.mesh(id, 0);

		test::@check(mesh.vertex_count == 8, "eight corners, got %d", mesh.vertex_count);
		test::@check(mesh.index_count == 24, "twelve edges is twenty-four indices, got %d", mesh.index_count);
		test::@check(mesh.bounds.min.x == -0.5f && mesh.bounds.max.x == 0.5f, "corners at +/- 0.5, got %s", mesh.bounds);
	};
}

<*
 One segment, origin to +X, one unit long.

 +X rather than +Y so that "the length is the X scale" is true — which is what
 lets `AxesHelper` be three meshes over *one* asset instead of three assets.
*>
fn void the_segment_runs_from_the_origin_along_x() @test
{
	@with_js(; three::JsRuntime* run)
	{
		three::AssetId id = run.pass.assets.lines(&run.renderer.gpu, { .kind = three::LineKind.SEGMENT })!!;
		three::GpuMesh* mesh = run.pass.assets.mesh(id, 0);

		test::@check(mesh.vertex_count == 2 && mesh.index_count == 2, "one segment, got %d verts %d indices",
			mesh.vertex_count, mesh.index_count);
		test::@check(mesh.bounds.min.x == 0 && mesh.bounds.min.y == 0 && mesh.bounds.min.z == 0,
			"it starts at the origin, got %s", mesh.bounds.min);
		test::@check(mesh.bounds.max.x == 1 && mesh.bounds.max.y == 0 && mesh.bounds.max.z == 0,
			"it ends one unit along +X, got %s", mesh.bounds.max);
	};
}

<*
 A grid of `n` divisions is `2 * (n + 1)` segments, ruled both ways.
*>
fn void a_grid_is_ruled_both_ways() @test
{
	@with_js(; three::JsRuntime* run)
	{
		three::AssetId id = run.pass.assets.lines(&run.renderer.gpu,
			{ .kind = three::LineKind.GRID, .divisions = 4 })!!;
		three::GpuMesh* mesh = run.pass.assets.mesh(id, 0);

		// 5 lines each way, 2 vertices each, 2 directions.
		test::@check(mesh.vertex_count == 20, "5 lines each way is 20 vertices, got %d", mesh.vertex_count);
		test::@check(mesh.index_count == 20, "10 segments is 20 indices, got %d", mesh.index_count);
	};
}

<*
 The grid is keyed on its divisions and the other two shapes are keyed on nothing.

 This is what makes `GridHelper(100, 10)` and `GridHelper(40, 10)` one asset at
 two scales — the size is the transform's job. A box asked for with a stray
 division count is still the one box asset, which matters because `LineShape` has
 the field whether or not the shape reads it.
*>
fn void a_line_shape_is_keyed_on_what_it_reads() @test
{
	@with_js(; three::JsRuntime* run)
	{
		three::Assets* assets = &run.pass.assets;
		three::Gpu* gpu = &run.renderer.gpu;

		three::AssetId box = assets.lines(gpu, { .kind = three::LineKind.BOX })!!;
		three::AssetId box_again = assets.lines(gpu, { .kind = three::LineKind.BOX, .divisions = 17 })!!;
		test::@check(box.index == box_again.index, "the divisions are not part of a box's key");

		three::AssetId ten = assets.lines(gpu, { .kind = three::LineKind.GRID, .divisions = 10 })!!;
		three::AssetId ten_again = assets.lines(gpu, { .kind = three::LineKind.GRID, .divisions = 10 })!!;
		three::AssetId four = assets.lines(gpu, { .kind = three::LineKind.GRID, .divisions = 4 })!!;

		test::@check(ten.index == ten_again.index, "the same grid twice is one asset");
		test::@check(ten.index != four.index, "two division counts are two assets");
		test::@check(ten.index != box.index, "a grid is not a box");
	};
}

<*
 A helper carries no picking tree, and that is a feature rather than an omission.

 `upload_built` skips `build_bvh` for a line mesh because the index buffer is
 pairs and the tree would read it in threes — a tree over triangles that do not
 exist, and `scene.pick` answering with a hit on a debug helper. The absence is
 also what makes a click go through the box onto the thing it is drawn around,
 which is checked from the other end in `a_click_goes_through_a_helper`.
*>
fn void a_line_mesh_has_no_picking_tree() @test
{
	@with_js(; three::JsRuntime* run)
	{
		three::AssetId id = run.pass.assets.lines(&run.renderer.gpu, { .kind = three::LineKind.BOX })!!;
		three::GpuMesh* mesh = run.pass.assets.mesh(id, 0);

		test::@check(mesh.hull_positions.len == 0, "no CPU positions, got %d", mesh.hull_positions.len);
		test::@check(mesh.hull_triangles.len == 0, "no CPU triangles, got %d", mesh.hull_triangles.len);
	};
}

// ============================================================================
// Wireframes
// ============================================================================

<*
 Every shared edge is drawn once, not once per triangle that owns it.

 A plane is the case where the number can be argued rather than measured: four
 vertices, two triangles, and five distinct edges — the four sides and the
 diagonal the quad was split along. Emitting three edges per triangle gives
 twelve indices; the dedup gives ten. Both draw a picture that looks right, which
 is exactly why this is a count and not a render.
*>
fn void a_wireframe_draws_each_shared_edge_once() @test
{
	@with_js(; three::JsRuntime* run)
	{
		three::Assets* assets = &run.pass.assets;
		three::Gpu* gpu = &run.renderer.gpu;

		three::AssetId plane = assets.primitive(gpu,
			{ .kind = three::PrimitiveKind.PLANE, .a = 1, .b = 1, .u = 1, .v = 1, .w = 1 })!!;
		three::GpuMesh* source = assets.mesh(plane, 0);
		test::@check(source.vertex_count == 4 && source.index_count == 6,
			"the fixture is a two-triangle quad, got %d verts %d indices", source.vertex_count, source.index_count);

		three::AssetId wire = assets.wireframe(gpu, plane, 0)!!;
		three::GpuMesh* mesh = assets.mesh(wire, 0);

		test::@check(mesh.vertex_count == 4, "a wireframe has the mesh's own vertices, got %d", mesh.vertex_count);
		test::@check(mesh.index_count == 10,
			"four sides and one diagonal is ten indices — twelve would mean the dedup did nothing; got %d",
			mesh.index_count);
	};
}

<*
 A closed shape whose vertices are split per face still dedups within each face.

 A unit cube is 24 vertices rather than 8, because a corner needs a different
 normal on each of the three faces meeting there. So its edges do not dedup
 *across* faces — six faces of five edges each, thirty in total — and this is the
 check that the dedup is exact rather than approximately halving.
*>
fn void a_split_vertex_is_not_a_shared_edge() @test
{
	@with_js(; three::JsRuntime* run)
	{
		three::Assets* assets = &run.pass.assets;
		three::Gpu* gpu = &run.renderer.gpu;

		three::AssetId box = assets.primitive(gpu,
			{ .kind = three::PrimitiveKind.BOX, .a = 1, .b = 1, .c = 1, .u = 1, .v = 1, .w = 1 })!!;
		three::AssetId wire = assets.wireframe(gpu, box, 0)!!;
		three::GpuMesh* mesh = assets.mesh(wire, 0);

		test::@check(mesh.index_count == 60, "six faces of five edges is sixty indices, got %d", mesh.index_count);
	};
}

<*
 The same mesh twice is one wireframe asset.

 Keyed on the source asset's path and mesh index, so a script that makes a
 wireframe per copy of a piece gets one upload and one draw call — the same rule
 every other asset here follows.
*>
fn void a_wireframe_is_keyed_on_the_mesh_it_describes() @test
{
	@with_js(; three::JsRuntime* run)
	{
		three::Assets* assets = &run.pass.assets;
		three::Gpu* gpu = &run.renderer.gpu;

		three::AssetId box = assets.primitive(gpu,
			{ .kind = three::PrimitiveKind.BOX, .a = 1, .b = 1, .c = 1, .u = 1, .v = 1, .w = 1 })!!;
		three::AssetId first = assets.wireframe(gpu, box, 0)!!;
		three::AssetId second = assets.wireframe(gpu, box, 0)!!;

		test::@check(first.index == second.index, "the same mesh twice is one wireframe asset");
		test::@check(first.index != box.index, "the wireframe is its own asset, not the mesh's");
	};
}

<*
 A mesh nobody has placed has no triangles on this side, and that is a sentence.

 `Assets.load` describes a file; a mesh reaches the device — and its triangles
 reach the CPU copy the wireframe reads — when something drawing it is added to a
 scene. An empty wireframe would draw nothing and read as a helper that does not
 work, so the fault is distinct from "no such mesh".
*>
fn void a_wireframe_of_a_mesh_that_is_not_resident_says_so() @test
{
	@with_js(; three::JsRuntime* run)
	{
		three::Assets* assets = &run.pass.assets;
		three::Gpu* gpu = &run.renderer.gpu;

		three::AssetId kit = assets.load(gpu, "test/fixtures/textured.glb")!!;

		if (catch err = assets.wireframe(gpu, kit, 0))
		{
			test::@check(err == three::LINE_MESH_NOT_RESIDENT, "it says the mesh is not resident, got %s", err);
		}
		else
		{
			test::@check(false, "a mesh that was never uploaded has no triangles to read");
		}

		if (catch err = assets.wireframe(gpu, kit, 99))
		{
			test::@check(err == three::NO_SUCH_LINE_MESH, "an index past the end is its own fault, got %s", err);
		}
		else
		{
			test::@check(false, "mesh 99 does not exist");
		}
	};
}

// ============================================================================
// The JavaScript surface
// ============================================================================

<*
 **The check that keeps `prelude.js`'s literal `1` honest.**

 A helper's material is not something JavaScript can read back: `mesh.material`
 answers with the ShaderMaterial or null, and the host index is private. So the
 prelude spells `LINE_MATERIAL = 1` and nothing in the language connects it to
 `scene/material.c3`'s `const uint LINE_MATERIAL = 1`.

 This is that connection. It counts nodes carrying the host's own constant, and
 an AxesHelper is three of them — so renumbering the material on either side
 fails here rather than in a render six months later, which is the same trick
 `the_default_background_is_the_renderer_clear` plays on the clear colour.
*>
fn void a_helper_draws_with_the_line_material() @test
{
	@with_js(; three::JsRuntime* run)
	{
		three::RunResult result = run.run(`
			const scene = new three.Scene();
			scene.add(new three.Mesh(new three.BoxGeometry(1, 1, 1)));
			scene.add(new three.AxesHelper(1));
			return three.stats().instances;
		`);
		defer result.free();

		test::@check(result.ok, "the script succeeded: %s", result.error);
		test::@check(result.value == "4", "one box and three arms are four instances, got %s", result.value);

		test::@check(
			nodes_with_material(run, three::LINE_MATERIAL) == 3,
			"the three arms draw with the host's LINE_MATERIAL, got %d",
			nodes_with_material(run, three::LINE_MATERIAL)
		);
		test::@check(
			nodes_with_material(run, three::DEFAULT_MATERIAL) >= 1,
			"and the box still draws with the default one"
		);
	};
}

<*
 A thousand box helpers are one draw call.

 The claim the whole design rests on, and the reason debug draw is geometry here
 rather than a side channel: they share the unit-cube asset and differ by
 transform and colour, both of which ride in the instance record.
*>
fn void a_thousand_box_helpers_are_one_draw_call() @test
{
	@with_js(; three::JsRuntime* run)
	{
		three::RunResult result = run.run(`
			const scene = new three.Scene();
			for (let i = 0; i < 1000; i++) {
				const h = new three.Box3Helper(new three.Box3(-0.5, -0.5, -0.5, 0.5, 0.5, 0.5));
				h.position.x = i * 2;
				h.color = [i / 1000, 0, 1];
				scene.add(h);
			}
			const s = three.stats();
			return [s.drawCalls, s.uniqueMeshes, s.instances];
		`);
		defer result.free();

		test::@check(result.ok, "the script succeeded: %s", result.error);
		test::@check(result.value == "[1,1,1000]", "one call, one mesh, a thousand copies; got %s", result.value);
	};
}

<*
 Three arms, one asset, one draw call — and the colours are per copy.

 `AxesHelper` is where "colour is free" earns its keep: red, green and blue over
 one segment asset. Three assets would be three draw calls and three uploads for
 a shape that is two vertices.
*>
fn void an_axes_helper_is_three_meshes_over_one_asset() @test
{
	@with_js(; three::JsRuntime* run)
	{
		three::RunResult result = run.run(`
			const scene = new three.Scene();
			scene.add(new three.AxesHelper(1));
			scene.add(new three.AxesHelper(2));
			const s = three.stats();
			return [s.drawCalls, s.uniqueMeshes, s.instances, s.assets];
		`);
		defer result.free();

		test::@check(result.ok, "the script succeeded: %s", result.error);
		test::@check(result.value == "[1,1,6,1]", "two helpers are six arms over one asset in one call, got %s",
			result.value);
	};
}

<*
 The arms point along +X, +Y and +Z, and `size` scales all three.

 The rotations are the risky part — the segment asset points along +X and the
 other two are quarter turns — so this measures where the arms actually end up
 rather than reading the angles back.
*>
fn void the_axes_point_along_the_axes() @test
{
	@with_js(; three::JsRuntime* run)
	{
		three::RunResult result = run.run(`
			const axes = new three.AxesHelper(2);
			const box = axes.boundsInParent();
			return [box.min.toArray(), box.max.toArray()].flat().map(n => Math.round(n * 1000) / 1000);
		`);
		defer result.free();

		test::@check(result.ok, "the script succeeded: %s", result.error);
		// Three arms from the origin, two units along each positive axis.
		test::@check(result.value == "[0,0,0,2,2,2]", "the arms reach +2 on each axis and nowhere else, got %s",
			result.value);
	};
}

<*
 A box helper lands on the box it measured.

 The whole point, stated as the identity it has to satisfy: the helper's own box
 and the box of the thing it was drawn around are the same box. It is measured
 through `boundsInParent` on both sides, so a helper that was placed by centre
 and size rather than by min and max is caught by whichever half is wrong.
*>
fn void a_box_helper_lands_on_the_box_it_measured() @test
{
	@with_js(; three::JsRuntime* run)
	{
		three::RunResult result = run.run(`
			const scene = new three.Scene();
			const piece = new three.Mesh(new three.BoxGeometry(3, 0.2, 7));
			piece.position.set(5, 1, -2);
			piece.scale.set(1, 2, 1);
			scene.add(piece);
			scene.add(new three.BoxHelper(piece));

			const want = piece.boundsInParent();
			const got = scene.children[1].boundsInParent();
			const near = (a, b) => Math.abs(a - b) < 1e-4;
			return [
				near(want.min.x, got.min.x), near(want.min.y, got.min.y), near(want.min.z, got.min.z),
				near(want.max.x, got.max.x), near(want.max.y, got.max.y), near(want.max.z, got.max.z),
			].every(Boolean);
		`);
		defer result.free();

		test::@check(result.ok, "the script succeeded: %s", result.error);
		test::@check(result.value == "true", "the helper's box is the piece's box, got %s", result.value);
	};
}

<*
 It follows the piece when told to, and not before.

 Nothing watches the object — there is no update loop a helper could hook — so a
 helper made before a move draws where the object was. That is Three.js's
 behaviour and Three.js's `update()`, and it is worth pinning because the failure
 mode is a box that is *plausible* and wrong.
*>
fn void a_box_helper_follows_the_piece_when_updated() @test
{
	@with_js(; three::JsRuntime* run)
	{
		three::RunResult result = run.run(`
			const scene = new three.Scene();
			const piece = new three.Mesh(new three.BoxGeometry(1, 1, 1));
			scene.add(piece);
			const helper = new three.BoxHelper(piece);
			scene.add(helper);

			piece.position.x = 10;
			const stale = helper.position.x;
			helper.update();
			const fresh = helper.position.x;
			return [stale, fresh];
		`);
		defer result.free();

		test::@check(result.ok, "the script succeeded: %s", result.error);
		test::@check(result.value == "[0,10]", "stale until update(), then on the piece; got %s", result.value);
	};
}

<*
 A box helper hangs from the object's own parent, and says so anywhere else.

 `boundsInParent` measures in the parent's frame, so a helper under a different
 parent is drawn wherever those two frames happen to differ. Refused rather than
 answered with a box in the wrong place, which is `alignTo`'s rule and `alignTo`'s
 reason.
*>
fn void a_box_helper_refuses_a_parent_that_is_not_the_objects() @test
{
	@with_js(; three::JsRuntime* run)
	{
		three::RunResult result = run.run(`
			const scene = new three.Scene();
			const group = new three.Group();
			group.position.set(100, 0, 0);
			scene.add(group);

			const piece = new three.Mesh(new three.BoxGeometry(1, 1, 1));
			group.add(piece);

			try { scene.add(new three.BoxHelper(piece)); return 'no throw'; }
			catch (e) { return e.message; }
		`);
		defer result.free();

		test::@check(result.ok, "the script succeeded: %s", result.error);
		test::@check(result.value.contains("same parent"), "it says which parent, got '%s'", result.value);
	};
}

<*
 A helper cannot be given a ShaderMaterial.

 Not a style rule: a material *is* a pipeline, and every pipeline a script can
 build draws triangles. Handing one to a mesh whose indices are pairs reads the
 pairs as triangles — geometry that is wrong rather than absent, which is the
 worst of the three outcomes.
*>
fn void a_helper_refuses_a_shader_material() @test
{
	@with_js(; three::JsRuntime* run)
	{
		three::RunResult result = run.run(`
			const grid = new three.GridHelper(10, 10);
			const mat = new three.ShaderMaterial({
				uniforms: { k: 1 },
				fragment: "float3 shade(Surface s) { return float3(k, 0, 0); }"
			});
			try { grid.material = mat; return 'no throw'; }
			catch (e) { return e.message; }
		`);
		defer result.free();

		test::@check(result.ok, "the script succeeded: %s", result.error);
		test::@check(result.value.contains("line material"), "it says what a helper draws with, got '%s'",
			result.value);
		test::@check(nodes_with_material(run, three::LINE_MATERIAL) == 0, "and nothing was assigned");
	};
}

<*
 A grid is the size it was asked for, and two sizes are one asset.

 The unit square is scaled rather than rebuilt, which is what keeps a scene of
 several grids to one draw call — and is why `GridHelper` has `divisions` to read
 back but no `size`: the size is `scale`, and `scale` is live.
*>
fn void a_grid_helper_is_a_unit_square_scaled() @test
{
	@with_js(; three::JsRuntime* run)
	{
		three::RunResult result = run.run(`
			const scene = new three.Scene();
			const wide = new three.GridHelper(100, 10);
			const small = new three.GridHelper(4, 10);
			scene.add(wide, small);
			const box = wide.boundsInParent();
			const s = three.stats();
			return [box.size.x, box.size.z, wide.divisions, s.drawCalls, s.uniqueMeshes];
		`);
		defer result.free();

		test::@check(result.ok, "the script succeeded: %s", result.error);
		test::@check(result.value == "[100,100,10,1,1]",
			"100 units across, 10 divisions, and both grids in one call; got %s", result.value);
	};
}

<*
 A wireframe needs the mesh on the device, and says which door that is.

 The one helper with a precondition. A generated shape is uploaded when it is
 constructed, so it works detached; a mesh out of a file reaches the device when
 something drawing it is added to a scene, and until then there are no triangles
 to read. Both halves are checked, because "it works for a box and not for a kit
 piece" is the shape of the surprise.
*>
fn void a_wireframe_helper_needs_the_mesh_on_the_device() @test
{
	@with_js(; three::JsRuntime* run)
	{
		three::RunResult result = run.run(`
			const generated = new three.WireframeHelper(new three.BoxGeometry(1, 1, 1)) ? 'built' : '';

			const kit = three.load("test/fixtures/textured.glb");
			let refused = '';
			try { new three.WireframeHelper(kit.mesh("quad_left")); }
			catch (e) { refused = e.message; }

			const scene = new three.Scene();
			const piece = new three.Mesh(kit.mesh("quad_left"));
			scene.add(piece);
			piece.add(new three.WireframeHelper(piece));

			const s = three.stats();
			return { generated, refused, drawCalls: s.drawCalls, instances: s.instances };
		`);
		defer result.free();

		test::@check(result.ok, "the script succeeded: %s", result.error);
		test::@check(result.value.contains("built"), "a generated shape wireframes detached, got %s", result.value);
		test::@check(result.value.contains("scene.add(mesh) first"),
			"and a file's mesh says which door, got %s", result.value);
		// The quad and its wireframe are two assets and two materials, so two calls.
		test::@check(result.value.contains(`"drawCalls":2`), "the quad and its edges are two calls, got %s",
			result.value);
	};
}

<*
 A click goes through a helper onto the thing it is drawn around.

 The other end of `a_line_mesh_has_no_picking_tree`, and the property that makes
 a helper usable in a scene an agent is clicking on: a box helper is drawn
 *around* something, so it is between the camera and the thing every time, and a
 helper that could be picked would make every click select the helper.
*>
fn void a_click_goes_through_a_helper() @test
{
	@with_js(; three::JsRuntime* run)
	{
		three::RunResult result = run.run(`
			const scene = new three.Scene();
			const piece = new three.Mesh(new three.BoxGeometry(1, 1, 1));
			piece.name = 'piece';
			scene.add(piece);

			const helper = new three.Box3Helper(new three.Box3(-2, -2, -2, 2, 2, 2));
			helper.name = 'helper';
			scene.add(helper);

			three.camera.lookAt(0, 0, 0);
			three.camera.orbit(0, 0, 8);
			three.render(scene);

			const { width, height } = three.renderSize();
			const hit = scene.pick(width / 2, height / 2);
			return hit === null ? 'nothing' : hit.name;
		`);
		defer result.free();

		test::@check(result.ok, "the script succeeded: %s", result.error);
		test::@check(result.value == `"piece"`, "the click reaches the piece, not the box drawn around it; got %s",
			result.value);
	};
}
