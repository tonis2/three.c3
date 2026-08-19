<*
 Getting the scene back out: the `.glb` writer, and what survives the crossing.

	`c3c test --trust=full --test-noleak --test-filter three_tests::export`

 `plan.md` §5 states the milestone and its acceptance in one sentence — "a glTF
 writer that emits one `mesh` per unique asset and one `node` per instance, with
 materials and textures deduplicated by content hash across every source file.
 Done when a scene built by a script round-trips through `.glb` and loads back
 with the same draw-call count." `a_scene_round_trips_with_the_same_draw_calls`
 is that sentence, executed.

 ## Why the draw-call count is the assertion and not the file

 A file can be inspected for a mesh count and still be wrong in the way that
 matters: two nodes referencing one mesh and two nodes referencing two identical
 meshes produce the same picture and differ by a factor of N in what they cost to
 draw. **The reload is what can tell them apart**, because `Assets.load` buckets
 on `(asset, mesh, material)` and a file that duplicated its geometry comes back
 as one bucket per copy. So every check here that is about sharing goes through a
 load rather than through the bytes.

 ## What is deliberately lost, and why it is checked

 Three things do not survive, each for a reason `scene/export.c3` argues:
 helpers and hidden subtrees, because the export is what the frame shows;
 `ShaderMaterial`s, because a material here is a Slang pipeline and glTF
 describes surfaces; and per-copy colour *as a per-copy thing*, because glTF has
 no per-instance channel and each colour therefore needs its own material. The
 last one is the only place the round-trip claim has a caveat, so it has a test
 of its own stating the shape of the caveat rather than a comment claiming it is
 small.
*>
module three_tests::export;

import three;
import vk;
import qjs;
import std::core::test;
import std::io;
import std::io::file;
import std::math;

const String FIXTURE = "test/fixtures/textured.glb";

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
// The acceptance check
// ============================================================================

<*
 **`plan.md` §5's sentence, run.**

 A scene of three shapes, thirty copies each, out to a `.glb` and back. Every
 number that describes the scene's cost has to survive: the draw calls, the
 unique meshes and the instances.

 The scene is rebuilt from the file through `asset.instantiate()`, which is the
 door a script would use, rather than through anything the exporter knows about
 — so the two halves have no shared implementation to agree wrongly through.
*>
fn void a_scene_round_trips_with_the_same_draw_calls() @test
{
	String path = "build/export_roundtrip.glb";
	defer (void)file::delete(path);

	@with_js(; three::JsRuntime* run)
	{
		three::RunResult result = run.run(`
			const scene = new three.Scene();
			const shapes = [
				new three.BoxGeometry(1, 1, 1),
				new three.SphereGeometry(0.6, 16, 8),
				new three.CylinderGeometry(0.4, 0.4, 1.2, 12),
			];
			shapes.forEach((shape, s) => {
				for (let i = 0; i < 30; i++) {
					const m = new three.Mesh(shape);
					m.position.set(i * 1.5, s * 2, 0);
					scene.add(m);
				}
			});
			const before = three.stats();
			const report = scene.export("build/export_roundtrip.glb");

			// A fresh scene, and the file read back through the ordinary door.
			const after_scene = new three.Scene();
			const asset = three.load("build/export_roundtrip.glb");
			after_scene.add(asset.instantiate());
			const after = three.stats();

			return {
				before: [before.drawCalls, before.uniqueMeshes, before.instances],
				after: [after.drawCalls, after.uniqueMeshes, after.instances],
				wrote: [report.meshes, report.entries, report.instances],
			};
		`);
		defer result.free();

		test::@check(result.ok, "the script succeeded: %s", result.error);
		test::@check(
			result.value == `{"before":[3,3,90],"after":[3,3,90],"wrote":[3,3,90]}`,
			"three shapes and ninety copies, out and back unchanged; got %s",
			result.value
		);
	};
}

<*
 The file says what the frame says about sharing.

 A thousand copies of one shape are one mesh and a thousand nodes, and the proof
 that the geometry was not duplicated is the *reload*: a file with a thousand
 copies of the vertices comes back as a thousand buckets, because `Assets.load`
 makes a `GpuMesh` per primitive and the renderer buckets on it.
*>
fn void a_thousand_copies_are_one_mesh_in_the_file() @test
{
	String path = "build/export_shared.glb";
	defer (void)file::delete(path);

	@with_js(; three::JsRuntime* run)
	{
		three::RunResult result = run.run(`
			const scene = new three.Scene();
			const shape = new three.BoxGeometry(1, 1, 1);
			for (let i = 0; i < 1000; i++) {
				const m = new three.Mesh(shape);
				m.position.x = i;
				scene.add(m);
			}
			const report = scene.export("build/export_shared.glb");

			new three.Scene();
			const asset = three.load("build/export_shared.glb");
			return [report.meshes, report.entries, asset.meshes.length];
		`);
		defer result.free();

		test::@check(result.ok, "the script succeeded: %s", result.error);
		test::@check(result.value == "[1,1,1]", "one mesh written, one mesh in the file; got %s", result.value);
	};
}

// ============================================================================
// Where the vertices came from
// ============================================================================

<*
 A generated shape is tessellated again rather than read back off the device.

 Nothing keeps a generated shape's normals or uvs on the CPU — that is the trade
 `scene/export.c3` makes, thirty-two bytes of `Primitive` per asset against
 twenty per vertex — so the exporter runs the generator a second time. This is
 the check that it produces the same shape: the reloaded box has the same vertex
 count, the same triangle count and the same extent as the one that was written.
*>
fn void a_generated_shape_is_tessellated_again() @test
{
	String path = "build/export_generated.glb";
	defer (void)file::delete(path);

	@with_js(; three::JsRuntime* run)
	{
		three::RunResult result = run.run(`
			const scene = new three.Scene();
			const box = new three.Mesh(new three.BoxGeometry(2, 3, 4));
			scene.add(box);
			const before = three.stats();
			scene.export("build/export_generated.glb");

			new three.Scene();
			const asset = three.load("build/export_generated.glb");
			const size = asset.meshAt(0).bounds.size;
			const reloaded = new three.Scene();
			reloaded.add(asset.instantiate());
			const after = three.stats();

			return [
				before.vertices, after.vertices,
				before.triangles, after.triangles,
				size.x, size.y, size.z,
			];
		`);
		defer result.free();

		test::@check(result.ok, "the script succeeded: %s", result.error);
		test::@check(result.value == "[24,24,12,12,2,3,4]",
			"the same 24 vertices, 12 triangles and 2x3x4 extent came back; got %s", result.value);
	};
}

<*
 A hull comes back with its faces, out of the picking tree's copy.

 A convex hull has no `Primitive` to regenerate from and no file to re-read, so
 it is the one shape rebuilt from `hull_positions`/`hull_triangles`. Its normals
 are recomputed rather than stored, and that is exact rather than approximate:
 `build_convex` splits a vertex per face, so each vertex belongs to one triangle
 and the accumulated normal is that triangle's.
*>
fn void a_hull_comes_back_out_of_the_picking_tree() @test
{
	String path = "build/export_hull.glb";
	defer (void)file::delete(path);

	@with_js(; three::JsRuntime* run)
	{
		three::RunResult result = run.run(`
			const scene = new three.Scene();
			// A unit tetrahedron: four faces, twelve split vertices.
			const hull = new three.ConvexGeometry([
				[0, 0, 0], [1, 0, 0], [0, 1, 0], [0, 0, 1],
			]);
			scene.add(new three.Mesh(hull));
			const before = three.stats();
			scene.export("build/export_hull.glb");

			new three.Scene();
			const asset = three.load("build/export_hull.glb");
			const reloaded = new three.Scene();
			reloaded.add(asset.instantiate());
			const after = three.stats();
			return [before.triangles, after.triangles, before.vertices, after.vertices];
		`);
		defer result.free();

		test::@check(result.ok, "the script succeeded: %s", result.error);
		test::@check(result.value == "[4,4,12,12]",
			"four faces and twelve split vertices, out and back; got %s", result.value);
	};
}

<*
 A mesh out of a file is re-read from the file, normals, uvs and texture intact.

 The exact path: the stream is still open, so what is written out is the bytes
 that were read in. The texture surviving is the half a picture would show and a
 count would not, so the reloaded asset is checked for having uploaded one.
*>
fn void a_file_mesh_keeps_its_texture() @test
{
	String path = "build/export_textured.glb";
	defer (void)file::delete(path);

	@with_js(; three::JsRuntime* run)
	{
		three::RunResult result = run.run(`
			const kit = three.load("test/fixtures/textured.glb");
			const scene = new three.Scene();
			scene.add(new three.Mesh(kit.mesh("quad_left")));
			scene.add(new three.Mesh(kit.mesh("quad_right")));
			const report = scene.export("build/export_textured.glb");

			new three.Scene();
			three.unloadUnused();
			const asset = three.load("build/export_textured.glb");
			const reloaded = new three.Scene();
			reloaded.add(asset.instantiate());
			const after = three.stats();

			return { images: report.images, meshes: report.meshes, textures: after.textures };
		`);
		defer result.free();

		test::@check(result.ok, "the script succeeded: %s", result.error);
		test::@check(result.value == `{"images":1,"meshes":2,"textures":1}`,
			"two meshes over one image, and the image came back; got %s", result.value);
	};
}

<*
 An image two files share is written once.

 The dedup the plan asks for, and it needed no hashing here: `GpuMesh.texture` is
 already an index into the shared table, which is deduplicated by a hash of the
 decoded image across every loaded file. Keying the exported image on that index
 *is* the content hash, reused — so this is the check that the reuse is real.

 Two files rather than two meshes of one file, because a file's own images are
 already shared by a memo and would pass this without the hash existing at all.
*>
fn void an_image_two_files_share_is_written_once() @test
{
	String copy = "build/export_copy.glb";
	String path = "build/export_two_files.glb";
	char[]? source = file::load_temp(FIXTURE);
	test::@check(@ok(source), "could not read %s — regenerate it with test/fixtures/make_textured.py", FIXTURE);
	file::save(copy, source!!)!!;
	defer (void)file::delete(copy);
	defer (void)file::delete(path);

	@with_js(; three::JsRuntime* run)
	{
		three::RunResult result = run.run(`
			const a = three.load("test/fixtures/textured.glb");
			const b = three.load("build/export_copy.glb");
			const scene = new three.Scene();
			scene.add(new three.Mesh(a.mesh("quad_left")));
			scene.add(new three.Mesh(b.mesh("quad_left")));

			const report = scene.export("build/export_two_files.glb");
			return [report.meshes, report.images, three.stats().textures];
		`);
		defer result.free();

		test::@check(result.ok, "the script succeeded: %s", result.error);
		test::@check(result.value == "[2,1,1]",
			"two files' meshes are two meshes over one image, as they are one texture on the device; got %s",
			result.value);
	};
}

// ============================================================================
// What does not survive, on purpose
// ============================================================================

<*
 Helpers and hidden subtrees are not in the file.

 One rule with two consequences: the export is what the frame shows. A `.glb`
 with the debug boxes baked into it is a file nobody wants, and a subtree that is
 switched off is not part of the picture being exported.

 `skipped` is what makes this visible to a script rather than a silence.
*>
fn void helpers_and_hidden_subtrees_are_not_in_the_file() @test
{
	String path = "build/export_visible.glb";
	defer (void)file::delete(path);

	@with_js(; three::JsRuntime* run)
	{
		three::RunResult result = run.run(`
			const scene = new three.Scene();

			const piece = new three.Mesh(new three.BoxGeometry(1, 1, 1));
			scene.add(piece);
			scene.add(new three.BoxHelper(piece));
			scene.add(new three.GridHelper(10, 10));

			const hidden = new three.Group();
			hidden.visible = false;
			hidden.add(new three.Mesh(new three.SphereGeometry(1, 8, 4)));
			scene.add(hidden);

			const report = scene.export("build/export_visible.glb");

			new three.Scene();
			const asset = three.load("build/export_visible.glb");
			const reloaded = new three.Scene();
			reloaded.add(asset.instantiate());

			return {
				wrote: [report.meshes, report.instances, report.skipped],
				back: three.stats().drawCalls,
				meshes: asset.meshes,
			};
		`);
		defer result.free();

		test::@check(result.ok, "the script succeeded: %s", result.error);
		test::@check(
			result.value == `{"wrote":[1,1,3],"back":1,"meshes":["box"]}`,
			"the box went, the two helpers and the hidden group did not; got %s",
			result.value
		);
	};
}

<*
 A ShaderMaterial's geometry is exported and its shader is not, and it says so.

 A material here is a Slang pipeline; glTF describes surfaces, not programs.
 Dropping the mesh would be worse than dropping the shader — the geometry is
 what an exported scene is mostly for — so the mesh goes out with the base colour
 and texture it carries, and `shaded` is how a script finds out.
*>
fn void a_shader_material_exports_its_geometry_and_says_so() @test
{
	String path = "build/export_shaded.glb";
	defer (void)file::delete(path);

	@with_js(; three::JsRuntime* run)
	{
		three::RunResult result = run.run(`
			const scene = new three.Scene();
			const mat = new three.ShaderMaterial({
				uniforms: { tint: [1, 0, 0] },
				fragment: "float3 shade(Surface s) { return tint; }"
			});
			scene.add(new three.Mesh(new three.BoxGeometry(1, 1, 1), mat));
			scene.add(new three.Mesh(new three.SphereGeometry(1, 8, 4)));

			const report = scene.export("build/export_shaded.glb");
			return [report.meshes, report.instances, report.shaded];
		`);
		defer result.free();

		test::@check(result.ok, "the script succeeded: %s", result.error);
		test::@check(result.value == "[2,2,1]",
			"both meshes went out and one of them lost a shader; got %s", result.value);
	};
}

<*
 **The one place the round-trip claim has a caveat, stated rather than hidden.**

 `mesh.color` is per copy and free here because it rides in the instance record.
 glTF has no per-instance channel at all — a material belongs to a primitive, a
 primitive to a mesh, and a node points at a mesh — so two copies of one shape in
 two colours need two materials and therefore two `mesh` entries.

 The *vertices* are still written once and referenced by both, which is what
 `meshes` counting 1 while `entries` counts 2 means. What does not survive is the
 draw call: three colours come back as three buckets where they drew as one.
*>
fn void a_colour_per_copy_becomes_a_material_per_colour() @test
{
	String path = "build/export_colours.glb";
	defer (void)file::delete(path);

	@with_js(; three::JsRuntime* run)
	{
		three::RunResult result = run.run(`
			const scene = new three.Scene();
			const shape = new three.BoxGeometry(1, 1, 1);
			[[1, 0, 0], [0, 1, 0], [0, 0, 1]].forEach((colour, i) => {
				for (let n = 0; n < 4; n++) {
					const m = new three.Mesh(shape);
					m.color = colour;
					m.position.set(n, i, 0);
					scene.add(m);
				}
			});
			const before = three.stats();
			const report = scene.export("build/export_colours.glb");

			new three.Scene();
			const asset = three.load("build/export_colours.glb");
			const reloaded = new three.Scene();
			reloaded.add(asset.instantiate());
			const after = three.stats();

			return {
				wrote: [report.meshes, report.entries, report.materials],
				drawCalls: [before.drawCalls, after.drawCalls],
				instances: [before.instances, after.instances],
			};
		`);
		defer result.free();

		test::@check(result.ok, "the script succeeded: %s", result.error);
		test::@check(
			result.value == `{"wrote":[1,3,3],"drawCalls":[1,3],"instances":[12,12]}`,
			"one set of vertices under three materials, and one draw call becomes three; got %s",
			result.value
		);
	};
}

// ============================================================================
// Refusals
// ============================================================================

<*
 An empty scene is a sentence rather than a file with nothing in it.

 A zero-byte-of-content `.glb` on disk is the kind of success that costs an hour:
 the export "worked", the viewer shows nothing, and the question becomes which of
 the two ends is broken.
*>
fn void an_empty_scene_says_there_is_nothing_to_write() @test
{
	@with_js(; three::JsRuntime* run)
	{
		three::RunResult result = run.run(`
			const scene = new three.Scene();
			try { scene.export("build/export_never.glb"); return 'no throw'; }
			catch (e) { return e.message; }
		`);
		defer result.free();

		test::@check(result.ok, "the script succeeded: %s", result.error);
		test::@check(result.value.contains("nothing to export"), "it says what is wrong, got '%s'", result.value);
		test::@check(!file::is_file("build/export_never.glb"), "and it wrote no file");
	};
}

<*
 A scene of nothing but helpers is the same refusal.

 Worth its own check because it is the one an agent actually hits: a scene that
 draws is on screen, so "export it" after adding a grid and some boxes is the
 natural next thing — and a scene holding only the grid would otherwise write a
 file whose entire contents were excluded.
*>
fn void a_scene_of_only_helpers_has_nothing_to_export() @test
{
	@with_js(; three::JsRuntime* run)
	{
		three::RunResult result = run.run(`
			const scene = new three.Scene();
			scene.add(new three.GridHelper(10, 10));
			scene.add(new three.AxesHelper(1));
			try { scene.export("build/export_helpers_only.glb"); return 'no throw'; }
			catch (e) { return e.message; }
		`);
		defer result.free();

		test::@check(result.ok, "the script succeeded: %s", result.error);
		test::@check(result.value.contains("helper"), "it names the reason, got '%s'", result.value);
		test::@check(!file::is_file("build/export_helpers_only.glb"), "and it wrote no file");
	};
}

fn void an_export_wants_a_path() @test
{
	@with_js(; three::JsRuntime* run)
	{
		three::RunResult result = run.run(`
			const scene = new three.Scene();
			scene.add(new three.Mesh(new three.BoxGeometry(1, 1, 1)));
			try { scene.export(""); return 'no throw'; }
			catch (e) { return e.message; }
		`);
		defer result.free();

		test::@check(result.ok, "the script succeeded: %s", result.error);
		test::@check(result.value.contains("wants a path"), "it says so, got '%s'", result.value);
	};
}
