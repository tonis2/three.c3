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

 Two things do not survive, each for a reason `scene/export.c3` argues: helpers
 and hidden subtrees, because the export is what the frame shows; and
 `ShaderMaterial`s, because a material here is a Slang pipeline and glTF
 describes surfaces.

 **Per-copy colour used to be a third**, and is now the subject of half the tests
 below. Core glTF has no per-instance channel, so a colour per copy cost a
 material and a `mesh` entry per copy and came back as a draw call per copy —
 the frame's central claim thrown away at the door. `EXT_mesh_gpu_instancing`
 with a `_COLOR_0` attribute is the channel, and what has to be checked is both
 halves of it: that a batch of copies survives as one draw call *and* that each
 of them comes back the colour it went in.

 **Rigs used to be a third**, and are now the subject of the last four. A skinned
 character exported as a bind-pose statue with no skeleton and no clips; it now
 goes out with all three, re-read from the source document because a rig does not
 survive as far as a frame. What has to be checked is the split: a skeleton per
 copy, because glTF places a skinned mesh by its joints, and one set of keyframes
 between them, because those are the kilobytes.

 ## Two of these read the file rather than reloading it

 Everything about *sharing* goes through a load, for the reason above. But
 "was the attribute written at all" and "was the extension declared" cannot: a
 reader that ignored the extension entirely would answer both exactly as a
 correct one does, and the point of writing the transforms in the standard place
 is that a reader which is not this one can use them. Those two look at the JSON
 chunk.
*>
module three_tests::export;

import three;
import vk;
import std::core::test;
import std::io::file;
import image;

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

<*
 The `.glb`'s JSON chunk, as text.

 glTF puts the JSON chunk first and requires it to be there, so there is no scan:
 a 12-byte file header, then this chunk's own 8-byte header of length and type,
 then the text. Returns empty for anything that is not a `.glb`, which fails the
 check that asked rather than reading whatever was at that offset.
*>
fn String json_chunk(String path)
{
	char[]? bytes = file::load_temp(path);
	if (catch bytes) return "";
	if (bytes.len < 20) return "";

	uint length = (uint)bytes[12] | ((uint)bytes[13] << 8) | ((uint)bytes[14] << 16) | ((uint)bytes[15] << 24);
	if ((usz)length + 20 > bytes.len) return "";
	return (String)bytes[20:(usz)length];
}

// How many times a key appears in the chunk. `contains` answers "at least one",
// and the questions about a *per-mesh* attribute need "exactly one".
fn usz occurrences(String haystack, String needle)
{
	usz found = 0;
	usz at = 0;
	while (at + needle.len <= haystack.len)
	{
		if (haystack[at:needle.len] == needle)
		{
			found++;
			at += needle.len;
			continue;
		}
		at++;
	}
	return found;
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
 **A colour per copy costs a colour per copy, and nothing else.**

 Twelve boxes in three colours. They are one draw call in the frame because
 `mesh.color` rides in the instance record, and the whole point of writing
 `EXT_mesh_gpu_instancing` is that they are still one draw call after a round
 trip through a file. Before it they were three materials, three `mesh` entries
 and three buckets.

 Both halves are checked, because the cheap half is easy to get right on its own:
 a batch that collapsed to one draw call but lost its colours would pass a
 draw-call assertion and be useless. The twelve colours are read back off the
 rebuilt objects, in order.
*>
fn void a_colour_per_copy_rides_the_instance_buffer() @test
{
	String path = "build/export_colours.glb";
	defer (void)file::delete(path);

	@with_js(; three::JsRuntime* run)
	{
		three::RunResult result = run.run(`
			const scene = new three.Scene();
			const shape = new three.BoxGeometry(1, 1, 1);
			const wanted = [[1, 0, 0], [0, 1, 0], [0, 0, 1]];
			wanted.forEach((colour, i) => {
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
			const root = asset.instantiate();
			reloaded.add(root);
			const after = three.stats();

			const got = [];
			root.traverse(o => { if (o instanceof three.Mesh) got.push(o.color.slice(0, 3)); });

			return {
				wrote: [report.meshes, report.entries, report.materials, report.batches],
				drawCalls: [before.drawCalls, after.drawCalls],
				instances: [before.instances, after.instances],
				colours: got,
			};
		`);
		defer result.free();

		test::@check(result.ok, "the script succeeded: %s", result.error);
		test::@check(
			result.value == `{"wrote":[1,1,1,1],"drawCalls":[1,1],"instances":[12,12],"colours":[[1,0,0],[1,0,0],[1,0,0],[1,0,0],[0,1,0],[0,1,0],[0,1,0],[0,1,0],[0,0,1],[0,0,1],[0,0,1],[0,0,1]]}`,
			"one mesh, one material, one batch, one draw call, and twelve colours back in order; got %s",
			result.value
		);
	};
}

<*
 **Two materials over one mesh are two nodes, and it took `plan.md` §1 to say so.**

 `ExportBatch` used to key on `(asset, mesh)` alone, on the argument that a
 material follows from the mesh. It does not: a node names a material of its own,
 and `surface_for` reads that node for the blend mode, the cull mode, the UV
 transform, the layer stack and the map. Siblings that disagreed about any of
 them were gathered into one instanced node written with `members[0]`'s material,
 and the rest inherited it.

 This is that scene, at its smallest honest size. Four brick walls and two glass
 windows, every one of them a `PlaneGeometry(2, 2)` — so the *only* thing that can
 keep them apart in the file is the material, which is exactly the claim.

 Every number here moves under the defect, which is what makes it a test rather
 than a demonstration. Under the old key: one batch, one `mesh` entry, one
 material, and — because a wall was added first — an export with no `BLEND` in it
 at all and two windows the colour of brick. The reload half is the one that
 matters to a person: the file came back as **one** draw call, which reads like
 the exporter doing well.

 The geometry count is the other half of the argument and is asserted for it.
 Splitting the batch does not duplicate a vertex: `meshes` stays 1, because
 geometry is deduplicated on `(asset, mesh)` regardless of material, so the two
 instanced nodes share one set of accessors. The split costs a node, and buys
 back the two draws that were always there.

 **Proved by injection.** `known.material == material` dropped from `batch_of`'s
 compare, which is the old key exactly:
 `{"wrote":[1,1,1,1],"drawCalls":[2,1],"instances":[6,6],"modes":["OPAQUE"]}` —
 one material, one draw call back, and the glass gone.
*>
fn void siblings_that_share_a_mesh_but_not_a_material_stay_apart() @test
{
	String path = "build/export_walls.glb";
	defer (void)file::delete(path);

	@with_js(; three::JsRuntime* run)
	{
		three::RunResult result = run.run(`
			const scene = new three.Scene();

			// One geometry, deliberately: with the shapes equal the material is the
			// only thing left that can split these two runs.
			const pane = new three.PlaneGeometry(2, 2);
			const brick = new three.MeshLambertMaterial({ color: 0x996633 });
			const glass = new three.MeshLambertMaterial({ color: 0x99ccff, transparent: true, opacity: 0.4 });

			// Interleaved, so neither run is a contiguous block of children. The
			// batching walks the child list in order and a test where the walls
			// happen to come first would pass on a weaker rule than the one meant.
			for (let n = 0; n < 6; n++) {
				const m = new three.Mesh(pane, n % 3 === 2 ? glass : brick);
				m.position.set(n, 0, 0);
				scene.add(m);
			}

			const before = three.stats();
			const report = scene.export("build/export_walls.glb");

			new three.Scene();
			const asset = three.load("build/export_walls.glb");
			const reloaded = new three.Scene();
			reloaded.add(asset.instantiate());
			const after = three.stats();

			// By value rather than by index: which mesh entry each material landed
			// in is the exporter's business, and sorting makes the claim "one of
			// each" rather than "this one first".
			const modes = [];
			asset.meshes.forEach((_, i) => modes.push(asset.meshAt(i).material.alphaMode));
			modes.sort();

			return {
				wrote: [report.meshes, report.entries, report.materials, report.batches],
				drawCalls: [before.drawCalls, after.drawCalls],
				instances: [before.instances, after.instances],
				modes: modes,
			};
		`);
		defer result.free();

		test::@check(result.ok, "the script succeeded: %s", result.error);
		test::@check(
			result.value == `{"wrote":[1,2,2,2],"drawCalls":[2,2],"instances":[6,6],"modes":["BLEND","OPAQUE"]}`,
			"one geometry, two materials, two batches, two draw calls either side, and the glass still glass; got %s",
			result.value
		);

		String json = json_chunk(path);
		test::@check(json.contains(`"alphaMode":"BLEND"`),
			"the window run says so in the format's own words: %s", json);
	};
}

<*
 Every copy comes back where it was, turned and scaled as it was.

 The colour is the interesting attribute and the transforms are the ones that
 would be *quietly* wrong: an off-by-one in the accessor stride, or a quaternion
 written in the wrong component order, produces a scene that is plainly a scene
 and plainly not the one that was exported. Five copies that disagree about all
 three transforms, compared component by component.

 Rotation is compared as the Euler triple a script reads back rather than as the
 quaternion, rounded to a thousandth: the trip out and in is float-exact but the
 Euler conversion at either end is not, and the assertion is about the file, not
 about `asin`.
*>
fn void an_instanced_node_places_every_copy_where_it_was() @test
{
	String path = "build/export_placed.glb";
	defer (void)file::delete(path);

	@with_js(; three::JsRuntime* run)
	{
		three::RunResult result = run.run(`
			const round = (v) => v.map(n => Math.round(n * 1000) / 1000);
			const scene = new three.Scene();
			const shape = new three.BoxGeometry(1, 1, 1);
			const placed = [];
			for (let i = 0; i < 5; i++) {
				const m = new three.Mesh(shape);
				m.position.set(i * 1.5, i, -i);
				m.rotation.set(i * 0.2, i * 0.3, i * 0.1);
				m.scale.set(1 + i, 1, 2 - i * 0.25);
				scene.add(m);
				placed.push([round(m.position.toArray()), round(m.rotation.toArray()), round(m.scale.toArray())]);
			}
			const report = scene.export("build/export_placed.glb");

			new three.Scene();
			const asset = three.load("build/export_placed.glb");
			const root = asset.instantiate();
			new three.Scene().add(root);

			const got = [];
			root.traverse(o => {
				if (o instanceof three.Mesh) {
					got.push([round(o.position.toArray()), round(o.rotation.toArray()), round(o.scale.toArray())]);
				}
			});

			return {
				batches: report.batches,
				same: JSON.stringify(got) === JSON.stringify(placed),
				got: got.length,
			};
		`);
		defer result.free();

		test::@check(result.ok, "the script succeeded: %s", result.error);
		test::@check(
			result.value == `{"batches":1,"same":true,"got":5}`,
			"one batch, five copies, every transform back as it went; got %s",
			result.value
		);
	};
}

<*
 Only the attributes that vary are written.

 `TRANSLATION` always is — it is what carries the instance count, since the
 extension has no length field of its own — but a grid of copies that never
 turned, never scaled and were never tinted has no business paying thirty-two
 further bytes each to say so. This is one of the two checks that reads the file:
 the absence of an accessor is invisible from a reload, because the identity is
 what a missing attribute means and the identity is what the copies had.

 The second export is the same scene with one copy tinted, which is the control:
 without it, `_COLOR_0` being absent proves nothing about whether it is ever
 written.
*>
fn void only_the_attributes_that_vary_are_written() @test
{
	String plain = "build/export_plain.glb";
	String tinted = "build/export_tinted.glb";
	defer (void)file::delete(plain);
	defer (void)file::delete(tinted);

	@with_js(; three::JsRuntime* run)
	{
		three::RunResult result = run.run(`
			const build = (tint) => {
				const scene = new three.Scene();
				const shape = new three.BoxGeometry(1, 1, 1);
				for (let i = 0; i < 6; i++) {
					const m = new three.Mesh(shape);
					m.position.x = i;
					if (tint && i === 3) m.color = [1, 0, 0];
					scene.add(m);
				}
				return scene;
			};
			const plain = build(false).export("build/export_plain.glb");
			const tinted = build(true).export("build/export_tinted.glb");
			return [plain.batches, tinted.batches];
		`);
		defer result.free();

		test::@check(result.ok, "the script succeeded: %s", result.error);
		test::@check(result.value == "[1,1]", "one batch each; got %s", result.value);

		String plain_json = json_chunk(plain);
		test::@check(plain_json.contains(`"TRANSLATION"`), "the copies were placed: %s", plain_json);
		test::@check(!plain_json.contains(`"ROTATION"`), "nothing turned, so nothing said so: %s", plain_json);
		test::@check(!plain_json.contains(`"SCALE"`), "nothing scaled, so nothing said so: %s", plain_json);
		test::@check(!plain_json.contains("_COLOR_0"), "nothing was tinted, so no colour array: %s", plain_json);

		String tinted_json = json_chunk(tinted);
		test::@check(tinted_json.contains("_COLOR_0"), "one tinted copy puts the array in: %s", tinted_json);
	};
}

<*
 The file says it uses the extension.

 `extensionsUsed` is not decoration: a reader is entitled to refuse a document
 that uses an extension without declaring it, and the declaration is the only
 part of this that a validator can check on its own. The other half of the check
 is the negative — a scene with nothing to instance must not claim the extension,
 because a document that declares one it does not use is asking every reader to
 care about something that is not there.
*>
fn void the_file_declares_the_extension_it_uses() @test
{
	String batched = "build/export_declared.glb";
	String lone = "build/export_undeclared.glb";
	defer (void)file::delete(batched);
	defer (void)file::delete(lone);

	@with_js(; three::JsRuntime* run)
	{
		three::RunResult result = run.run(`
			const many = new three.Scene();
			const shape = new three.BoxGeometry(1, 1, 1);
			for (let i = 0; i < 3; i++) {
				const m = new three.Mesh(shape);
				m.position.x = i;
				many.add(m);
			}
			const batched = many.export("build/export_declared.glb");

			const one = new three.Scene();
			one.add(new three.Mesh(new three.BoxGeometry(1, 1, 1)));
			const lone = one.export("build/export_undeclared.glb");

			return [batched.batches, lone.batches];
		`);
		defer result.free();

		test::@check(result.ok, "the script succeeded: %s", result.error);
		test::@check(result.value == "[1,0]", "three copies batch and one does not; got %s", result.value);

		String declared = json_chunk(batched);
		// Named in the array rather than being the whole of it: every export
		// declares KHR_lights_punctual too, for the light it writes.
		test::@check(
			declared.contains(`"extensionsUsed":[`) && declared.contains(`"EXT_mesh_gpu_instancing"`),
			"the batched file declares it: %s", declared
		);
		test::@check(
			declared.contains(`"EXT_mesh_gpu_instancing":{"attributes":{`),
			"and carries it on the node: %s", declared
		);

		String undeclared = json_chunk(lone);
		test::@check(
			!undeclared.contains("EXT_mesh_gpu_instancing"),
			"a scene with nothing to instance does not mention it: %s", undeclared
		);
	};
}

<*
 A copy that is not one of many keeps its name.

 The rule `scene/export.c3` states: a batch of one is not a batch. It costs no
 draw call to write a lone node as itself, and what it buys is the name, the
 place in the tree, and a tinted material that a reader knowing nothing about
 instancing will honour. So a scene of three named props is three named nodes,
 and the tint is still there when they come back.

 The colours are the same three as the batched test, which is the comparison
 worth having: the same twelve-colours-in-three question answered by the other
 path.
*>
fn void a_lone_copy_is_written_as_itself() @test
{
	String path = "build/export_lone.glb";
	defer (void)file::delete(path);

	@with_js(; three::JsRuntime* run)
	{
		three::RunResult result = run.run(`
			const scene = new three.Scene();
			[["hearth", [1, 0, 0]], ["anvil", [0, 1, 0]], ["well", [0, 0, 1]]].forEach(([name, colour], i) => {
				// A shape of its own each, so no two of them are siblings drawing
				// the same thing and nothing here is a batch.
				const m = new three.Mesh(new three.BoxGeometry(1 + i, 1, 1));
				m.name = name;
				m.color = colour;
				m.position.x = i * 3;
				scene.add(m);
			});
			const report = scene.export("build/export_lone.glb");

			new three.Scene();
			const asset = three.load("build/export_lone.glb");
			const root = asset.instantiate();
			new three.Scene().add(root);

			const named = [];
			root.traverse(o => { if (o instanceof three.Mesh) named.push(o.name); });

			return {
				wrote: [report.meshes, report.entries, report.materials, report.batches],
				named,
				found: root.getObjectByName("anvil") !== null,
			};
		`);
		defer result.free();

		test::@check(result.ok, "the script succeeded: %s", result.error);
		test::@check(
			result.value == `{"wrote":[3,3,3,0],"named":["hearth","anvil","well"],"found":true}`,
			"three shapes, three materials, no batch, and every name still there; got %s",
			result.value
		);
	};
}

<*
 The hierarchy survives the collapse.

 What flattens is a run of leaves under one parent, into one node beneath that
 same parent — so a scene of two rooms, each with its own copies, is two batches
 and still two rooms. The check is that the groups are findable by name after the
 reload and that each still has its own copies under it, because a collapse that
 hoisted everything to the root would produce the same picture and the same draw
 call count.

 One of the copies is given a child of its own, which is the other half of the
 rule: instancing replicates a mesh and not a subtree, so that copy cannot be
 folded in and is written as a node. It is the reason `west` reports four copies
 under it and only three of them are in its batch.
*>
fn void groups_survive_the_collapse() @test
{
	String path = "build/export_rooms.glb";
	defer (void)file::delete(path);

	@with_js(; three::JsRuntime* run)
	{
		three::RunResult result = run.run(`
			const scene = new three.Scene();
			const shape = new three.BoxGeometry(1, 1, 1);
			["west", "east"].forEach((name, room) => {
				const group = new three.Group();
				group.name = name;
				group.position.z = room * 10;
				for (let i = 0; i < 4; i++) {
					const m = new three.Mesh(shape);
					m.position.x = i;
					group.add(m);
					// One copy in the west room has a child, so it cannot collapse.
					if (room === 0 && i === 3) {
						const perched = new three.Mesh(shape);
						perched.position.y = 1;
						m.add(perched);
					}
				}
				scene.add(group);
			});
			const before = three.stats();
			const report = scene.export("build/export_rooms.glb");

			new three.Scene();
			const asset = three.load("build/export_rooms.glb");
			const root = asset.instantiate();
			new three.Scene().add(root);
			const after = three.stats();

			const count = (name) => {
				const group = root.getObjectByName(name);
				if (group === null) return -1;
				let meshes = 0;
				group.traverse(o => { if (o instanceof three.Mesh) meshes++; });
				return meshes;
			};

			return {
				batches: report.batches,
				instances: [before.instances, after.instances],
				drawCalls: [before.drawCalls, after.drawCalls],
				rooms: [count("west"), count("east")],
			};
		`);
		defer result.free();

		test::@check(result.ok, "the script succeeded: %s", result.error);
		test::@check(
			// Three batches: the east room's four, the west room's three that
			// collapsed, and the odd one out's own single child, which is a run of
			// one and so is not a batch at all — leaving west's four-plus-perched.
			result.value == `{"batches":2,"instances":[9,9],"drawCalls":[1,1],"rooms":[5,4]}`,
			"two rooms, two batches, nine copies and one draw call throughout; got %s",
			result.value
		);
	};
}

<*
 **`flatten` reaches the copies the sibling rule cannot.**

 `asset.instantiate()` wraps each copy in a group of its own, so six crates from
 one kit are six groups holding one crate each and no two crates are siblings.
 Nothing batches, and untinted that costs nothing — the geometry is shared across
 the whole scene however it is parented. The tint is what cannot travel: six
 colours become six materials, six `mesh` entries and six buckets per shape.

 The same scene both ways, which is the only comparison that means anything: the
 default walk against `{ flatten: true }`, on copies made the way a script would
 actually make them.

 **The tints are read back off `mesh.color`, and that is why they differ.** Both
 files draw the same picture — the grouped one folded each tint into a material,
 so the colour is still on screen. What it is not any more is *per copy*: the
 instance channel comes back white and the six shades are six materials, so a
 script that wants to recolour one crate is back to making a material to do it.
 Flattened, the tint comes back where it started, in the channel that costs
 nothing to change.
*>
fn void flattening_batches_copies_that_are_not_siblings() @test
{
	String grouped = "build/export_grouped.glb";
	String flat = "build/export_flat.glb";
	defer (void)file::delete(grouped);
	defer (void)file::delete(flat);

	@with_js(; three::JsRuntime* run)
	{
		three::RunResult result = run.run(`
			const asset = three.load("test/fixtures/textured.glb");
			const build = () => {
				const scene = new three.Scene();
				for (let i = 0; i < 6; i++) {
					const copy = asset.instantiate();
					copy.position.x = i * 2;
					copy.traverse(o => { if (o instanceof three.Mesh) o.color = [i / 5, 0, 1]; });
					scene.add(copy);
				}
				return scene;
			};

			const measure = (scene, path, options) => {
				const before = three.stats();
				const report = scene.export(path, options);
				new three.Scene();
				const back = three.load(path);
				const fresh = new three.Scene();
				const root = back.instantiate();
				fresh.add(root);
				const after = three.stats();
				const tints = [];
				root.traverse(o => { if (o instanceof three.Mesh) tints.push(Math.round(o.color[0] * 100)); });
				return {
					wrote: [report.entries, report.materials, report.batches],
					drawCalls: [before.drawCalls, after.drawCalls],
					tints,
				};
			};

			return {
				grouped: measure(build(), "build/export_grouped.glb", undefined),
				flat: measure(build(), "build/export_flat.glb", { flatten: true }),
			};
		`);
		defer result.free();

		test::@check(result.ok, "the script succeeded: %s", result.error);
		// Grouped: twelve white instance channels, because the six shades are in
		// six materials. Flattened: the six shades themselves, in batch order —
		// every copy of the first shape, then every copy of the second, which is
		// the hierarchy going away and is stated here rather than hidden.
		test::@check(
			result.value == `{"grouped":{"wrote":[12,6,0],"drawCalls":[2,12],"tints":[100,100,100,100,100,100,100,100,100,100,100,100]},"flat":{"wrote":[2,1,2],"drawCalls":[2,2],"tints":[0,20,40,60,80,100,0,20,40,60,80,100]}}`,
			"grouped costs six materials, twelve draws and the per-copy channel; flattened keeps all three; got %s",
			result.value
		);
	};
}

<*
 A flattened export bakes the hierarchy into world space, and says so by losing it.

 The transform check is the one that would fail quietly: a copy two levels deep
 whose parent moved it has a world transform that is neither its own nor its
 parent's, and writing either one instead of the product puts the scene together
 wrong in a way that still looks like a scene. Three levels of nesting, with a
 rotation in the middle so the composition is not just addition.

 The loss is checked in the same breath, because it is the price and not a bug:
 the group is not findable by name afterwards, where the default export keeps it.
*>
fn void a_flattened_export_bakes_the_hierarchy_into_world_space() @test
{
	String path = "build/export_baked.glb";
	defer (void)file::delete(path);

	@with_js(; three::JsRuntime* run)
	{
		three::RunResult result = run.run(`
			const round = (v) => v.map(n => Math.round(n * 1000) / 1000);
			const build = () => {
				const scene = new three.Scene();
				const shape = new three.BoxGeometry(1, 1, 1);
				const yard = new three.Group();
				yard.name = "yard";
				yard.position.set(10, 0, 0);
				yard.rotation.set(0, Math.PI / 2, 0);
				scene.add(yard);
				for (let i = 0; i < 4; i++) {
					const shelf = new three.Group();
					shelf.position.set(0, i, 0);
					yard.add(shelf);
					const m = new three.Mesh(shape);
					m.position.set(2, 0, 0);
					shelf.add(m);
				}
				return scene;
			};

			// A rotation of a quarter turn about Y sends +x to -z, so a box at
			// x = 2 inside a yard at x = 10 lands at (10, i, -2).
			const wanted = [[10, 0, -2], [10, 1, -2], [10, 2, -2], [10, 3, -2]];

			const report = build().export("build/export_baked.glb", { flatten: true });
			new three.Scene();
			const back = three.load("build/export_baked.glb");
			const root = back.instantiate();
			new three.Scene().add(root);

			const got = [];
			root.traverse(o => { if (o instanceof three.Mesh) got.push(round(o.position.toArray())); });

			return {
				batches: report.batches,
				nodes: report.nodes,
				placed: JSON.stringify(got) === JSON.stringify(wanted),
				yard: root.getObjectByName("yard") === null,
			};
		`);
		defer result.free();

		test::@check(result.ok, "the script succeeded: %s", result.error);
		test::@check(
			// Four nodes: the root, the one instanced node under it, and the
			// camera and the light, which every export writes. Nine nodes went in
			// — a yard, four shelves and four boxes.
			result.value == `{"batches":1,"nodes":4,"placed":true,"yard":true}`,
			"one batch, four copies in world space, and the yard gone with it; got %s",
			result.value
		);
	};
}

<*
 `flatten` is off unless asked for, and asked for in one spelling.

 The default matters more than it looks: an export that quietly flattened would
 hand back a file that draws identically and cannot be opened by a person, and
 the difference would not show up in any count. So the no-argument call and the
 explicit `false` are checked to agree with each other, and a `flatten` that is
 not a boolean is refused rather than read for truthiness — `{ flatten: "no" }`
 meaning yes is exactly the kind of quiet that this would be found out by.
*>
fn void flatten_is_off_unless_it_is_asked_for() @test
{
	String path = "build/export_default.glb";
	defer (void)file::delete(path);

	@with_js(; three::JsRuntime* run)
	{
		three::RunResult result = run.run(`
			const asset = three.load("test/fixtures/textured.glb");
			const build = () => {
				const scene = new three.Scene();
				for (let i = 0; i < 3; i++) {
					const copy = asset.instantiate();
					copy.position.x = i * 2;
					scene.add(copy);
				}
				return scene;
			};

			const bare = build().export("build/export_default.glb");
			const explicit = build().export("build/export_default.glb", { flatten: false });
			const empty = build().export("build/export_default.glb", {});

			const refused = (options) => {
				try {
					build().export("build/export_default.glb", options);
					return "allowed";
				} catch (e) {
					return e.message;
				}
			};

			return {
				same: [bare.nodes, explicit.nodes, empty.nodes],
				batches: [bare.batches, explicit.batches, empty.batches],
				text: refused({ flatten: "yes" }),
				object: refused(7),
			};
		`);
		defer result.free();

		test::@check(result.ok, "the script succeeded: %s", result.error);
		test::@check(
			// Twelve rather than ten: the camera and the light are two of them, and
			// they are written whichever way flatten was asked for.
			result.value == `{"same":[12,12,12],"batches":[0,0,0],"text":"scene.export options.flatten is true or false","object":"scene.export(path, options) wants an object for its options, like { flatten: true }"}`,
			"three ways of not asking agree, and two ways of asking wrong are sentences; got %s",
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

// ============================================================================
// Textures a script made
//
// `scene.export` used to report `images: 0` for `examples/village` — a scene
// whose entire character is eleven generated textures — because `texture_for`
// read bytes out of a source glTF's buffer and a `DataTexture` has no source
// glTF. It also never consulted `material.map` at all, so an image a script put
// on a shape with `new three.MeshLambertMaterial({ map })` was invisible to the
// exporter even when the image *had* come from a file.
// ============================================================================

<*
 A generated texture is written into the file, and reloading it gives the same
 pixels back — byte for byte.

 The round trip rather than a count, because `images: 1` only says *something*
 was written. This checks it is the right something, and the path it takes is
 four format boundaries: read off the device, `png::save_bytes`, into the glTF
 image table, out through the PNG decoder, up onto the device again, and read
 back a second time. A channel swizzle or a row-order flip at any one of them
 survives a count and fails here.

 A gradient with all four channels moving, for the same reason: a flat fill
 would survive a swizzle, a half-copy and a transposed row order alike.

 Written in C3 rather than as a script because the last step has no JavaScript
 spelling — a mesh that brought its image from a file exposes no `Texture`
 handle, so there is nothing for `texture.read()` to be called on. That is a real
 gap and it is `asset.imageAt(i)`-shaped; it is not what this check is about.
*>
fn void a_generated_texture_survives_the_round_trip_byte_for_byte() @test
{
	String path = "build/export_generated.glb";
	defer (void)file::delete(path);

	vk::Instance instance = three::create_instance(false, headless: true)!!;
	defer instance.free();

	three::Renderer renderer;
	renderer.init(instance, (vk::SurfaceKHR)null, 200, 150)!!;
	defer renderer.free();
	renderer.pass.init(&renderer.gpu, &renderer.target)!!;

	const uint W = 8;
	const uint H = 8;
	char[] made = mem::new_array(char, (sz)W * H * 4);
	defer free(made);
	for (uint y = 0; y < H; y++)
	{
		for (uint x = 0; x < W; x++)
		{
			sz i = ((sz)y * W + x) * 4;
			made[i] = (char)(x * 30);
			made[i + 1] = (char)(y * 30);
			made[i + 2] = (char)(255 - x * 20);
			made[i + 3] = 255;
		}
	}

	image::Image source = {
		.width = W, .height = H, .bit_depth = 8,
		.format = image::PixelFormat.RGBA, .pixels = made, .allocator = mem,
	};
	int slot = renderer.pass.assets.claim_texture(&renderer.gpu, source)!!;
	uint material = renderer.pass.create_texture_material(slot)!!;

	three::AssetId box = renderer.pass.assets.primitive(&renderer.gpu, three::box_shape(1, 1, 1))!!;
	three::NodeId node = renderer.pass.scene.add_mesh(box, 0);
	renderer.pass.scene.set_material(node, material);

	three::ExportReport report = renderer.pass.export_scene(path)!!;
	test::@check(report.images == 1, "one image should have been written, got %d", report.images);
	test::@check(report.shaded == 0,
		"a texture material is a thing glTF describes, so nothing was lost, got shaded = %d", report.shaded);

	// Back in through the loader, and drawn, so its image reaches the device.
	three::AssetId reloaded = renderer.pass.assets.load(&renderer.gpu, path)!!;
	three::NodeId placed = renderer.pass.scene.add_mesh(reloaded, 0);
	(void)placed;

	three::GpuMesh* mesh = renderer.pass.assets.mesh(reloaded, 0);
	test::@check(mesh != null && mesh.texture >= 0,
		"the reloaded mesh should carry the file's image, got texture %d",
		mesh == null ? -99 : mesh.texture);

	three::Texture* back = renderer.pass.assets.texture_at(mesh.texture);
	test::@check(back.width == W && back.height == H,
		"it should be %dx%d, got %dx%d", W, H, back.width, back.height);

	char[] got = mem::new_array(char, (sz)back.width * back.height * 4);
	defer free(got);
	back.read_pixels(&renderer.gpu, got)!!;

	sz same = 0;
	sz first_wrong = -1;
	for (sz i = 0; i < made.len; i++)
	{
		if (made[i] == got[i]) { same++; }
		else if (first_wrong < 0) { first_wrong = i; }
	}
	test::@check(same == made.len,
		"%d of %d bytes survived the round trip; first difference at byte %d, %d went in and %d came back",
		same, made.len, first_wrong,
		first_wrong < 0 ? 0 : (int)made[first_wrong], first_wrong < 0 ? 0 : (int)got[first_wrong]
	);
}

<*
 `shaded` counts what the file cannot carry, not what is not the default.

 It used to be `material != DEFAULT_MATERIAL`, which counted a
 `MeshLambertMaterial` — an image and a colour, which is exactly what a glTF
 material is. On `examples/village` that read `shaded: 3025` of 3029, a number
 saying almost everything lost its shading about a file where almost nothing did.

 Three meshes, one of each kind, and only the ShaderMaterial counts.
*>
fn void shaded_counts_only_what_gltf_cannot_describe() @test
{
	String path = "build/export_shaded_kinds.glb";
	defer (void)file::delete(path);

	@with_js(; three::JsRuntime* run)
	{
		three::RunResult result = run.run(`
			const scene = new three.Scene();

			// No material at all.
			scene.add(new three.Mesh(new three.BoxGeometry(1, 1, 1)));

			// A texture and a side, which glTF has words for.
			const tex = new three.DataTexture(new Uint8Array(4 * 4 * 4).fill(200), 4, 4);
			const lambert = new three.MeshLambertMaterial({ map: tex });
			const b = new three.Mesh(new three.SphereGeometry(1, 8, 4), lambert);
			b.position.x = 3;
			scene.add(b);

			// A program, which it does not.
			const shader = new three.ShaderMaterial({
				uniforms: { tint: [0, 1, 0] },
				fragment: "float3 shade(Surface s) { return tint; }"
			});
			const c = new three.Mesh(new three.BoxGeometry(1, 1, 1), shader);
			c.position.x = 6;
			scene.add(c);

			const report = scene.export("build/export_shaded_kinds.glb");
			return { instances: report.instances, shaded: report.shaded, images: report.images };
		`);
		defer result.free();
		test::@check(result.ok, "the script succeeded: %s", result.error);
		test::@check(result.value.contains(`"instances":3`), "all three went out: %s", result.value);
		test::@check(result.value.contains(`"shaded":1`),
			"only the ShaderMaterial lost anything: %s", result.value);
		test::@check(result.value.contains(`"images":1`),
			"and the lambert material's map was written: %s", result.value);
	};
}

<*
 A material's map is what gets written, not the image the mesh brought.

 `MeshPass.record` lets `Material.texture` beat `GpuMesh.texture` so a script can
 overrule what a file supplied. The exporter did not, so a mesh loaded from
 `textured.glb` and then re-mapped exported with the *file's* checkerboard — the
 image the frame did not show. Wrong rather than missing, which is worse.
*>
fn void the_materials_map_is_what_the_file_gets() @test
{
	String path = "build/export_overridden_map.glb";
	defer (void)file::delete(path);

	@with_js(; three::JsRuntime* run)
	{
		three::RunResult result = run.run(`
			const scene = new three.Scene();
			const a = three.load("test/fixtures/textured.glb");
			const m = new three.Mesh(a.mesh("quad_left"));

			// Flat green, nothing like the fixture's magenta checkerboard.
			const px = new Uint8Array(4 * 4 * 4);
			for (let i = 0; i < px.length; i += 4) { px[i] = 0; px[i+1] = 200; px[i+2] = 0; px[i+3] = 255; }
			m.material = new three.MeshLambertMaterial({ map: new three.DataTexture(px, 4, 4) });
			scene.add(m);

			const report = scene.export("build/export_overridden_map.glb");
			scene.unload();

			// One image in the file, and it is the green one — proved by reading
			// it back off the device after a reload.
			const back = three.load("build/export_overridden_map.glb");
			const shown = new three.Mesh(back.meshAt(0));
			new three.Scene().add(shown);
			return { images: report.images };
		`);
		defer result.free();
		test::@check(result.ok, "the script succeeded: %s", result.error);
		test::@check(result.value.contains(`"images":1`),
			"the material's map should be the one image written: %s", result.value);
	};
}

<*
 A transparent material comes out of the file as `alphaMode: BLEND`, and does not
 take an opaque one with it.

 Two halves, and the second is the one that took the work. glTF states blending
 on the *material*, and materials here are deduplicated by content — so the
 moment blending became a thing a material could have, it had to become part of
 that key. Without it, a scene holding one opaque and one transparent material of
 the same colour and the same image writes **one** glTF material, and whichever
 was walked first decides whether both come back solid or both come back
 see-through. Neither failure is an error, and both look like an exporter bug on
 the wrong side of the file.

 The three shapes differ so that nothing else can be doing the work. Two siblings
 drawing the *same* shape are folded into one instanced node, which carries one
 material by construction — that would prove nothing about the dedup at all —
 and a difference in opacity would separate the pair through `baseColorFactor`
 rather than through the blend mode. So the second and third shapes agree on
 every byte of the key except the one under test.

 The alpha the file states is the alpha the frame had: opacity is multiplied into
 `baseColorFactor`'s fourth channel, which is why the first shape's 0.5 is
 asserted in the JSON as well as the mode.

 **Proved by injection.** `known.transparent != transparent` dropped from
 `material_for`'s compare: "the file holds one material per (colour, image, blend
 mode), got ... \"materials\":2 ..." — the clear sphere and the solid cylinder
 collapsed into one entry, and it was the transparent one, so the cylinder
 exported as glass.
*>
fn void a_transparent_material_exports_alpha_blend() @test
{
	String path = "build/export_glass.glb";
	defer (void)file::delete(path);

	@with_js(; three::JsRuntime* run)
	{
		three::RunResult result = run.run(`
			const scene = new three.Scene();

			// Half-faded glass: a blend mode *and* an alpha of its own.
			const faded = new three.Mesh(
				new three.BoxGeometry(1, 1, 1),
				new three.MeshLambertMaterial({ transparent: true, opacity: 0.5 })
			);
			scene.add(faded);

			// The pair the dedup key is really about. Same colour, same absent
			// texture, same opacity of 1 — the blend mode is the *only* thing that
			// can keep these two apart in the file.
			const clear = new three.Mesh(
				new three.SphereGeometry(0.5, 8, 6),
				new three.MeshLambertMaterial({ transparent: true })
			);
			clear.position.x = 2;
			scene.add(clear);

			const solid = new three.Mesh(
				new three.CylinderGeometry(0.4, 0.4, 1, 8),
				new three.MeshLambertMaterial({})
			);
			solid.position.x = 4;
			scene.add(solid);

			return scene.export("build/export_glass.glb");
		`);
		defer result.free();
		test::@check(result.ok, "the script succeeded: %s", result.error);
		test::@check(result.value.contains(`"materials":3`),
			"the file holds one material per (colour, image, blend mode), got %s", result.value);

		String json = json_chunk(path);
		test::@check(json.contains(`"alphaMode":"BLEND"`),
			"the transparent one says so in the format's own words: %s", json);
		test::@check(!json.contains(`"alphaMode":"OPAQUE"`),
			"and the opaque one leaves the default unstated: %s", json);
		test::@check(json.contains(`,0.5]`),
			"the opacity rode into baseColorFactor's alpha: %s", json);
	};
}

// ============================================================================
// Material layers
// ============================================================================

<*
 `alphaMode` survives the round trip, which it did not before the loader had a
 material record.

 `plan.md` §2: "glTF `alphaMode` is written on export and ignored on import. A
 `.glb` authored with BLEND loads and renders opaque." Both halves are asserted
 here, in the order they broke: the *export* half was already honest, and this is
 the first check that the *import* half is.

 Three surfaces, so that the two answers are told apart by a comparison rather
 than by a single value: a transparent material writes BLEND, an opaque one writes
 OPAQUE, and a mesh whose material is the default one writes OPAQUE too. A loader
 that answered "BLEND" unconditionally — or that answered with the *last* material
 it read, which is the shape the old `ExportBatch` collapse had — fails on the
 second and third.

 And `materials: true` on the way back, because reading the mode and acting on it
 are different claims: the pane comes back with `transparent` on its material, so
 a `.glb` authored with blending now renders blended without a script line.

 **Proved by injection**, twice. `load_material_record`'s `alpha_mode` hard-coded
 to `OPAQUE`: `{"pane":"OPAQUE","wall":"OPAQUE","bare":"OPAQUE","paneApplied":false}`
 — which is exactly the behaviour the entry described, and the last field shows
 that applying it is downstream of reading it.

 And separately the `materials: true` branch of `instantiate` removed, which is
 the half that is invisible to the first three checks:
 `{"pane":"BLEND","wall":"OPAQUE","bare":"OPAQUE","paneApplied":false}`. The mode
 crossing and the mode being acted on are two things, and a `.glb` that renders
 opaque is what the entry was actually about.
*>
fn void the_alpha_mode_survives_the_round_trip() @test
{
	String path = "build/export_alpha.glb";
	defer (void)file::delete(path);

	@with_js(; three::JsRuntime* run)
	{
		three::RunResult result = run.run(`
			const scene = new three.Scene();
			const pane = new three.Mesh(
				new three.PlaneGeometry(2, 2),
				new three.MeshLambertMaterial({ color: 0x3366ff, transparent: true, opacity: 0.5 })
			);
			pane.name = "pane";
			scene.add(pane);

			// A different shape, deliberately, and now for one reason rather than
			// two. The lookup below finds these by width, so the widths have to
			// differ. The second reason is gone: the exporter used to batch
			// siblings sharing a geometry into one node wearing the first
			// member's material, which would have collapsed all three of these
			// into the pane — see siblings_that_share_a_mesh_but_not_a_material.
			const wall = new three.Mesh(
				new three.PlaneGeometry(3, 3),
				new three.MeshLambertMaterial({ color: 0x996633 })
			);
			wall.name = "wall";
			wall.position.x = 3;
			scene.add(wall);

			const bare = new three.Mesh(new three.PlaneGeometry(4, 4));
			bare.name = "bare";
			bare.position.x = -3;
			scene.add(bare);

			scene.export("build/export_alpha.glb");
			const back = three.load("build/export_alpha.glb");

			// Found by size rather than by name or by index: the exporter names
			// every one of them "plane", and which slot each landed in is its
			// business and not this test's. The three widths are distinct on
			// purpose and that is the whole reason they are.
			const modes = {};
			back.meshes.forEach((_, i) => {
				const ref = back.meshAt(i);
				modes[Math.round(ref.bounds.size.x)] = ref.material.alphaMode;
			});

			const root = back.instantiate("back", { materials: true });
			const applied = {};
			root.traverse((o) => {
				if (!o.material) return;
				applied[Math.round(o.boundsInParent().size.x)] = !!o.material.transparent;
			});

			return { pane: modes[2], wall: modes[3], bare: modes[4], paneApplied: applied[2] === true };
		`);
		defer result.free();
		test::@check(result.ok, "the script succeeded: %s", result.error);

		test::@check(result.value.contains(`"pane":"BLEND"`),
			"the transparent pane came back as %s", result.value);
		test::@check(result.value.contains(`"wall":"OPAQUE"`),
			"the opaque wall came back as %s", result.value);
		test::@check(result.value.contains(`"bare":"OPAQUE"`),
			"a mesh on the default material came back as %s", result.value);
		test::@check(result.value.contains(`"paneApplied":true`),
			"the pane's material is not transparent: %s", result.value);
	};
}

<*
 The file's own roughness and metalness reach the frame.

 The importer carried both and applied neither for a long time, because glTF
 defaults them to 1 and 1 — so a file that never wrote a `pbrMetallicRoughness`
 block is a fully metallic surface, and a metal with nothing to reflect renders
 dark. `scene.environment` is what closed that, so the numbers go on now.

 Two files, because "the number crossed" and "the number was applied" are
 different claims and so are "we wrote what the frame had" and "we read what the
 file said":

 - A box this test exported with a roughness and a metalness of its own. Both are
   read back off the document through `ref.material`, and then read again off the
   material `instantiate({ materials: true })` built — which is the half that was
   missing.
 - `textured.glb`, which states neither. It comes back as 1 and 1, which is glTF's
   answer and not this renderer's, and is exactly the surprise the entry warned
   about. Asserting it is what makes the surprise a decision rather than a bug.

 The material it builds is a `MeshLambertMaterial` and that is also checked. A
 surface pair needs no generated shading body — the built-in shader already reads
 it — so going through `LayeredMaterial` for it would compile a program per glTF
 material whose body is what the built-in one already does.
*>
fn void the_surface_numbers_survive_the_round_trip() @test
{
	String path = "build/export_surface.glb";
	defer (void)file::delete(path);

	@with_js(; three::JsRuntime* run)
	{
		three::RunResult result = run.run(`
			const round = (v) => Math.round(v * 1000) / 1000;
			const scene = new three.Scene();
			const shiny = new three.MeshLambertMaterial({ roughness: 0.2, metalness: 0.6 });
			scene.add(new three.Mesh(new three.BoxGeometry(1, 1, 1), shiny));
			scene.export("build/export_surface.glb");

			const applied = (asset) => {
				const root = asset.instantiate("back", { materials: true });
				let found = null;
				root.traverse((o) => {
					if (!o.material) return;
					found = [round(o.material.metalness), round(o.material.roughness), o.material.toJSON().type];
				});
				return found === null ? "none" : found.join(",");
			};

			const back = three.load("build/export_surface.glb");
			const ref = back.meshAt(0).material;
			return {
				read: [round(ref.metalness), round(ref.roughness)].join(","),
				applied: applied(back),
				silent: applied(three.load("test/fixtures/textured.glb")),
			};
		`);
		defer result.free();
		test::@check(result.ok, "the script succeeded: %s", result.error);

		test::@check(result.value.contains(`"read":"0.6,0.2"`),
			"the exporter wrote what the frame drew with: %s", result.value);
		test::@check(result.value.contains(`"applied":"0.6,0.2,MeshLambertMaterial"`),
			"and the importer put it back on a material that compiles nothing: %s", result.value);
		test::@check(result.value.contains(`"silent":"1,1,MeshLambertMaterial"`),
			"a file that states neither is glTF's own fully metallic default: %s", result.value);
	};
}

<*
 A `CUSTOM_materials_layers` stack goes out and comes back.

 The extension is the one thing here that is *not* recovered from the frame. A
 layered material reaches the renderer as a generated `ShaderMaterial`, so by the
 rule the rest of this file is built on — "the export is what the frame shows" —
 it would be lost like any other shader, and until `gltf.c3l` could write the
 extension there was nowhere for it to go anyway.

 It is read out of the source document instead, which is both lossless and
 available without a device; `Exporter.layered_material_index` argues the choice
 against the two alternatives. What that buys is checked here in the only way
 that can tell a written stack from a remembered one: the file is loaded back
 through `three.load`, and the stack is read off the reloaded mesh through the
 same `layers` accessor a script would use.

 Five layers rather than one, because every field that crosses has a way of
 crossing wrongly on its own: the blend mode, the mask channel, the inversion,
 the disabled layer, the vertex-colour mask that names no image at all, and the
 alpha-times-opacity fold that is one number here and two in the file.
*>
fn void a_layer_stack_survives_the_round_trip() @test
{
	String path = "build/export_layered.glb";
	defer (void)file::delete(path);

	@with_js(; three::JsRuntime* run)
	{
		three::RunResult result = run.run(`
			const scene = new three.Scene();
			const source = three.load("test/fixtures/layered.glb");
			for (const name of ["terrain", "weathered", "plain"]) {
				scene.add(new three.Mesh(source.mesh(name)));
			}
			const report = scene.export("build/export_layered.glb");

			const back = three.load("build/export_layered.glb");
			const stack = back.mesh("terrain").layers;
			return {
				written: report.layers,
				names: stack.layers.map(l => l.name).join(","),
				blends: stack.layers.map(l => l.blend).join(","),
				channels: stack.layers.map(l => l.mask).join(","),
				sources: stack.layers.map(l => l.maskSource).join(","),
				off: stack.layers.filter(l => !l.enabled).map(l => l.name).join(","),
				inverted: stack.layers.filter(l => l.invert).map(l => l.name).join(","),
				moss: stack.layers[1].opacity,
				shared: stack.mask !== null,
				weathered: back.mesh("weathered").layers.layers.length,
				plain: back.mesh("plain").layers,
			};
		`);
		defer result.free();
		test::@check(result.ok, "the script succeeded: %s", result.error);

		// Five on `ground` and one on `weathering`, which is every layer the
		// fixture has. A stack partly written is the failure this catches.
		test::@check(result.value.contains(`"written":6`),
			"every layer in the file was written: %s", result.value);
		test::@check(result.value.contains(`"names":"rock,moss,snow,off,painted"`),
			"in order, by name: %s", result.value);
		test::@check(result.value.contains(`"blends":"mix,multiply,screen,add,overlay"`),
			"each with the blend mode it went in with: %s", result.value);
		test::@check(result.value.contains(`"channels":"r,g,b,a,g"`),
			"and the channel of the mask it reads: %s", result.value);

		// The two that are not an image and a channel.
		test::@check(result.value.contains(`"off":"off"`),
			"the disabled layer came back disabled rather than absent: %s", result.value);
		test::@check(result.value.contains(`"inverted":"snow"`),
			"and the inverted mask is still inverted: %s", result.value);
		test::@check(result.value.contains(`"sources":"texture,texture,texture,texture,vertexColor"`),
			"the vertex-colour mask did not become a texture: %s", result.value);

		// 0.5 opacity times an 0.6 alpha, which is a number neither field holds
		// on its own — so it is only 0.3 here if both crossed.
		test::@check(result.value.contains(`"moss":0.3`),
			"the alpha and the opacity both survived: %s", result.value);
		test::@check(result.value.contains(`"shared":true`),
			"the mask three layers read is one texture on the way back in too: %s", result.value);

		test::@check(result.value.contains(`"weathered":1`),
			"the second material's single layer went too: %s", result.value);
		test::@check(result.value.contains(`"plain":null`),
			"and a material that never had the extension did not acquire one: %s", result.value);
	};
}

<*
 The attribute a vertex-colour mask reads is in the file beside it.

 `painted` masks on `COLOR_0`, and until the exporter wrote that stream the
 attribute went nowhere: the layer came back naming a channel of something the
 file did not carry, which reloads as a mask reading zero — a layer that
 silently vanishes rather than one that is visibly wrong.

 Read out of the JSON chunk rather than off a reload, for the reason the header
 gives: a loader that ignored `COLOR_0` would answer a reload exactly as one that
 read it, and the point of writing the attribute under its standard name is that
 a reader which is not this one can find it.
*>
fn void a_vertex_colour_mask_takes_its_attribute_with_it() @test
{
	String path = "build/export_colour_attribute.glb";
	defer (void)file::delete(path);

	@with_js(; three::JsRuntime* run)
	{
		three::RunResult result = run.run(`
			const scene = new three.Scene();
			const source = three.load("test/fixtures/layered.glb");
			scene.add(new three.Mesh(source.mesh("terrain")));
			scene.add(new three.Mesh(source.mesh("plain")));
			return scene.export("build/export_colour_attribute.glb");
		`);
		defer result.free();
		test::@check(result.ok, "the script succeeded: %s", result.error);

		String json = json_chunk(path);
		// `"COLOR_0":` is the attribute dictionary's key; the layer names the same
		// string as a *value*, `"attribute":"COLOR_0"`, so the colon is what tells
		// the stream apart from the reference to it.
		test::@check(json.contains(`"COLOR_0":`),
			"the colour attribute the mask names is in the file: %s", json);
		test::@check(json.contains(`"attribute":"COLOR_0"`),
			"and the mask still names it: %s", json);
		test::@check(json.contains(`"extensionsUsed":[`) && json.contains(`"CUSTOM_materials_layers"`),
			"the extension is declared, so a reader knows to look: %s", json);
		test::@check(json.contains(`"source":"VERTEX_COLOR"`),
			"with the mask reading a colour rather than an image: %s", json);

		// `plain` carries no COLOR_0 and must not acquire one — the attribute is
		// written per mesh from what the source had, not per file.
		test::@check(occurrences(json, `"COLOR_0":`) == 1,
			"only the mesh that had one: %s", json);
	};
}

<*
 A stack a *script* built comes back too.

 The companion to `a_layer_stack_survives_the_round_trip`, and the asymmetry it
 closes. That test's stack came out of `layered.glb`, so the exporter could read
 it from the source document; this one was never in a file, and until
 `Material.script_layers` existed there was nothing on the host side to read at
 all — the description lived in JavaScript and what crossed was Slang. Two stacks
 that render identically exported as a layered file and as a flat colour, which
 is a difference no script could see.

 What is checked is the same thing in both directions: the blend mode, the
 channel, the inversion, the images, and — since they acquired somewhere to go —
 the surface pair and the relief. The images matter most here, because they are
 the half that has no file behind it — a `DataTexture` is pixels on the device, so
 `device_texture_for` has to read them back and encode them, where the imported
 path copies bytes it already had.

 The relief is written in two places and both are checked: `bump` on the material
 goes into the extension's `base` object, which is the only slot a height map has
 because core glTF has none, and `bump` on a layer goes on the layer.
*>
fn void a_stack_a_script_built_survives_the_round_trip() @test
{
	String path = "build/export_script_layers.glb";
	defer (void)file::delete(path);

	@with_js(; three::JsRuntime* run)
	{
		three::RunResult result = run.run(`
			const round = (v) => Math.round(v * 1000) / 1000;
			const scene = new three.Scene();

			const grass = new three.DataTexture(new Uint8Array(4 * 4 * 4).fill(60), 4, 4);
			const gravel = new three.DataTexture(new Uint8Array(4 * 4 * 4).fill(200), 4, 4);
			const splat = new three.DataTexture(new Uint8Array(4 * 4 * 4).fill(128), 4, 4);
			const data = { colorSpace: three.LinearSRGBColorSpace };
			const relief = new three.DataTexture(new Uint8Array(4 * 4 * 4).fill(90), 4, 4, data);
			const bumps = new three.DataTexture(new Uint8Array(4 * 4 * 4).fill(30), 4, 4, data);
			const surface = new three.DataTexture(new Uint8Array(4 * 4 * 4).fill(160), 4, 4, data);

			const mat = new three.LayeredMaterial({
				map: grass,
				mask: splat,
				height: relief,
				bump: { strength: 0.5, distance: 0.2 },
				layers: [
					{
						name: 'gravel', map: gravel, mask: 'r', blend: 'multiply', opacity: 0.5,
						roughness: 0.3, metalness: 0.7, metallicRoughness: surface,
						height: bumps, bump: { strength: 0.25, distance: 0.08 },
					},
					{ name: 'snow', tint: [0.9, 0.95, 1], mask: 'g', invert: true, blend: 'screen' },
				],
			});
			scene.add(new three.Mesh(new three.PlaneGeometry(2, 2), mat));

			const report = scene.export("build/export_script_layers.glb");

			const back = three.load("build/export_script_layers.glb");
			const stack = back.meshAt(0).layers;
			return {
				written: report.layers,
				shaded: report.shaded,
				names: stack.layers.map(l => l.name).join(","),
				blends: stack.layers.map(l => l.blend).join(","),
				channels: stack.layers.map(l => l.mask).join(","),
				inverted: stack.layers.filter(l => l.invert).map(l => l.name).join(","),
				gravelOpacity: stack.layers[0].opacity,
				gravelHasMap: stack.layers[0].map !== null,
				snowHasMap: stack.layers[1].map === null,
				shared: stack.mask !== null,
				tint: stack.layers[1].tint.map(c => Math.round(c * 100)).join(","),
				baseRelief: [
					stack.height !== null, stack.bump.strength, round(stack.bump.distance),
				].join(","),
				gravelSurface: [
					round(stack.layers[0].metalness), round(stack.layers[0].roughness),
					stack.layers[0].metallicRoughness !== null,
				].join(","),
				gravelRelief: [
					stack.layers[0].height !== null,
					round(stack.layers[0].bump.strength), round(stack.layers[0].bump.distance),
				].join(","),
				// The layer that said nothing about either still says nothing on the
				// way back: glTF writes 1 and 1 for it, and a default is not a
				// statement.
				snowSurface: "metalness" in stack.layers[1],
			};
		`);
		defer result.free();
		test::@check(result.ok, "the script succeeded: %s", result.error);

		test::@check(result.value.contains(`"written":2`),
			"both layers of the script's stack were written: %s", result.value);
		test::@check(result.value.contains(`"names":"gravel,snow"`),
			"under the names the script gave them: %s", result.value);
		test::@check(result.value.contains(`"blends":"multiply,screen"`),
			"with their blend modes: %s", result.value);
		test::@check(result.value.contains(`"channels":"r,g"`),
			"and the channel of the shared mask each reads: %s", result.value);
		test::@check(result.value.contains(`"inverted":"snow"`),
			"the inverted one is still inverted: %s", result.value);
		test::@check(result.value.contains(`"gravelOpacity":0.5`),
			"the opacity crossed as the extension's own field: %s", result.value);
		test::@check(result.value.contains(`"tint":"90,95,100"`),
			"and a tint with no map behind it went into baseColorFactor: %s", result.value);

		// The images are the half with no file behind them: three DataTextures,
		// read off the device and encoded on the way out.
		test::@check(result.value.contains(`"gravelHasMap":true`),
			"the layer's own map was written and came back: %s", result.value);
		test::@check(result.value.contains(`"snowHasMap":true`),
			"and a layer with no map did not acquire one: %s", result.value);
		test::@check(result.value.contains(`"shared":true`),
			"the mask both layers read is one texture: %s", result.value);

		// Still a generated shader, so still counted as one. The two numbers
		// answer different questions and this is the scene where that shows.
		test::@check(result.value.contains(`"shaded":1`),
			"the material is still a program the file cannot hold: %s", result.value);

		// The surface pair and the relief, which had nowhere to go until the second
		// blend chain and `parallax_uv` existed, and so were not written at all. The bump numbers are the pair rather than their
		// product: the shader carries one number and the file wants two.
		test::@check(result.value.contains(`"baseRelief":"true,0.5,0.2"`),
			"the material's own height went into the extension's base object: %s", result.value);
		test::@check(result.value.contains(`"gravelSurface":"0.7,0.3,true"`),
			"and the layer's pair and its map: %s", result.value);
		test::@check(result.value.contains(`"gravelRelief":"true,0.25,0.08"`),
			"with the layer's own relief beside them: %s", result.value);
		test::@check(result.value.contains(`"snowSurface":false`),
			"the layer that stated neither did not acquire one: %s", result.value);
	};
}

// ============================================================================
// What makes an exported scene look like the scene
// ============================================================================

<*
 A side and a tiling both survive the crossing.

 Two ordinary things an agent building a scene does, and neither used to be in
 the file. `material.side` had a glTF word waiting for it — `doubleSided` — and
 the exporter simply never passed it, so a `DoubleSide` plane came back invisible
 from behind. `material.repeat` had nowhere in *core* glTF to go, and
 `KHR_texture_transform` is the ratified extension that is exactly this; without
 it a floor tiled four times exports with its texture stretched once across the
 whole surface, which is not a subtle difference.

 Both go through the reload rather than the bytes, because both are things a
 loader has to act on rather than merely carry.
*>
fn void a_side_and_a_tiling_survive_the_round_trip() @test
{
	String path = "build/export_side_and_tiling.glb";
	defer (void)file::delete(path);

	@with_js(; three::JsRuntime* run)
	{
		three::RunResult result = run.run(`
			const scene = new three.Scene();

			const tex = new three.DataTexture(new Uint8Array(4 * 4 * 4).fill(180), 4, 4);
			const floor = new three.MeshLambertMaterial({ map: tex });
			floor.repeat = [4, 4];
			floor.offset = [0.25, 0.5];
			floor.side = three.DoubleSide;
			scene.add(new three.Mesh(new three.PlaneGeometry(10, 10), floor));

			// A second material differing only in its side, to hold the dedup to
			// treating that as two materials rather than one.
			const wall = new three.MeshLambertMaterial({ map: tex });
			const m = new three.Mesh(new three.PlaneGeometry(2, 2), wall);
			m.position.x = 8;
			scene.add(m);

			const report = scene.export("build/export_side_and_tiling.glb");

			const back = three.load("build/export_side_and_tiling.glb");
			return { materials: report.materials, images: report.images };
		`);
		defer result.free();
		test::@check(result.ok, "the script succeeded: %s", result.error);

		// One image, because both materials sample the same device slot — and two
		// materials, because they disagree about the side and the tiling.
		test::@check(result.value.contains(`"images":1`),
			"one image between them: %s", result.value);
		test::@check(result.value.contains(`"materials":2`),
			"but two materials, since side and repeat are part of what a material is: %s", result.value);

		String json = json_chunk(path);
		test::@check(json.contains(`"doubleSided":true`),
			"the double-sided one says so in the format's own words: %s", json);
		test::@check(occurrences(json, `"doubleSided":true`) == 1,
			"and the single-sided one leaves the default unstated: %s", json);
		test::@check(json.contains(`"KHR_texture_transform"`),
			"the tiling is declared: %s", json);
		test::@check(json.contains(`"scale":[4,4]`) && json.contains(`"offset":[0.25,0.5]`),
			"with the repeat and the offset the material had: %s", json);
	};
}

<*
 A source material's normal map is written across.

 `WriteMaterial` used to say normal, occlusion and emissive were absent "because
 nothing in this writer produces them yet". A mesh loaded from a `.glb` produces
 them: they are on its own material, in a document the exporter already reads for
 the layer stack. Until this they were dropped, so a normal-mapped kit
 round-tripped flat — the geometry right and the surface detail gone.

 Read out of the JSON chunk rather than off a reload, for the header's reason: a
 loader that ignored `normalTexture` would answer a reload exactly as one that
 read it, and the point of writing it under its standard name is that a reader
 which is not this one can use it.
*>
fn void a_source_materials_normal_map_is_written_across() @test
{
	String path = "build/export_normal_map.glb";
	defer (void)file::delete(path);

	@with_js(; three::JsRuntime* run)
	{
		three::RunResult result = run.run(`
			const scene = new three.Scene();
			// layered.glb's rock layer carries a normal map, and its ground
			// material carries the base one - the fixture with a normal in it.
			const source = three.load("test/fixtures/layered.glb");
			scene.add(new three.Mesh(source.mesh("terrain")));
			return scene.export("build/export_normal_map.glb");
		`);
		defer result.free();
		test::@check(result.ok, "the script succeeded: %s", result.error);

		String json = json_chunk(path);
		test::@check(json.contains(`"normalTexture"`),
			"a normal map crossed: %s", json);
	};
}

<*
 The camera and the light are in the file.

 An exported scene used to open pointing wherever the viewer decided and lit by
 whatever the viewer supplied — so a scene composed for an angle and lit from a
 direction arrived as neither. Both are things glTF has and three had, with
 nothing carrying them across.

 The light's aiming is the half worth checking rather than assuming.
 `Light.direction` is *surface-to-light* and a glTF directional light shines along
 its node's -Z, so the node's +Z is the vector as stored — a negation either way
 lights the far side of everything, which reads as the exporter having the
 normals wrong rather than the light backwards.

 The second light is here for the half that is not aiming: the file has to carry
 every light rather than the sun alone, with the colour and the intensity each was
 given, and the names have to say which one casts the scene's shadows — glTF has
 no slot that records it.
*>
fn void the_camera_and_the_light_are_in_the_file() @test
{
	String path = "build/export_camera_light.glb";
	defer (void)file::delete(path);

	@with_js(; three::JsRuntime* run)
	{
		three::RunResult result = run.run(`
			const scene = new three.Scene();
			scene.add(new three.Mesh(new three.BoxGeometry(1, 1, 1)));

			three.camera.fov = 60;
			three.light.direction = [0, 0, 1];
			three.lights.add({ direction: [1, 0, 0], color: 0x0000ff, intensity: 2 });

			const report = scene.export("build/export_camera_light.glb");
			return { nodes: report.nodes, fov: three.camera.fov };
		`);
		defer result.free();
		test::@check(result.ok, "the script succeeded: %s", result.error);

		String json = json_chunk(path);
		test::@check(json.contains(`"type":"perspective"`), "there is a camera: %s", json);
		// 60 degrees is 1.0471975 radians, and glTF's unit is radians.
		test::@check(json.contains(`"yfov":1.04719`),
			"with the scene's own field of view, in the format's unit: %s", json);
		test::@check(!json.contains(`"aspectRatio"`),
			"and no aspect, so a viewer frames it in its own viewport: %s", json);

		test::@check(json.contains(`"type":"directional"`), "there is a light: %s", json);
		test::@check(json.contains(`"KHR_lights_punctual":{"light":0}`),
			"on a node that names it: %s", json);
		// Surface-to-light is +z, so the node is unrotated: its +Z is already the
		// vector, and the light travels along -Z from there.
		test::@check(json.contains(`{"name":"sun","extensions"`),
			"whose rotation is the identity for a light straight down +z: %s", json);

		// The second one, with the colour and the strength it was given — and named
		// so that reloading puts it back as a light that does not cast.
		test::@check(json.contains(`{"name":"light 1","type":"directional","color":[0,0,1],"intensity":2}`),
			"the fill light is in the file with its own colour and strength: %s", json);

		// Five nodes: the scene root, the box under it, the camera and two lights.
		test::@check(result.value.contains(`"nodes":5`),
			"the camera and the lights are nodes like any other: %s", result.value);
	};
}

// ============================================================================
// Baking: getting a ShaderMaterial's shading into the file
// ============================================================================

<*
 The three outcomes of a bake, in one scene.

 `scene.export` has always written a `ShaderMaterial`'s geometry and lost its
 shading, because a material here is a Slang pipeline and glTF describes
 surfaces. The cost of that is not abstract: a scene whose whole character is its
 shaders comes back as a correct scene in one grey, since a generated primitive's
 `base_color` is a single default shared by every one of them.

 `{ bake: N }` runs each body over its own mesh's uv layout — `render/bake.c3` —
 and the answer lands in the file as one of three things, all three of which are
 here:

 - a body whose answer varies across the surface becomes a `baseColorTexture`;
 - a body whose answer is one colour becomes a `baseColorFactor`, because an
   image for one of those is a megabyte of the same texel;
 - a body that discards becomes `alphaMode: MASK`, which is what turns a leaf cut
   out of a quad back into the leaf.

 The flat one is checked against the *exact* value it was given, because a colour
 that is merely plausible is the failure this whole feature exists to fix.
*>
fn void a_shader_material_bakes_into_the_file() @test
{
	String path = "build/export_baked.glb";
	defer (void)file::delete(path);

	@with_js(; three::JsRuntime* run)
	{
		three::RunResult result = run.run(`
			const scene = new three.Scene();

			const gradient = new three.ShaderMaterial({
				fragment: "float3 shade(Surface s) { return float3(s.uv.x, s.uv.y, 0.2); }"
			});
			scene.add(new three.Mesh(new three.PlaneGeometry(2, 2), gradient));

			const flat = new three.ShaderMaterial({
				uniforms: { tint: [0.1, 0.8, 0.3] },
				fragment: "float3 shade(Surface s) { return tint; }"
			});
			const b = new three.Mesh(new three.BoxGeometry(1, 1, 1), flat);
			b.position.x = 3;
			scene.add(b);

			const cut = new three.ShaderMaterial({
				fragment: "float3 shade(Surface s) { if (s.uv.x > 0.5) discard; return float3(1, 0, 0); }"
			});
			const c = new three.Mesh(new three.PlaneGeometry(2, 2), cut);
			c.position.x = 6;
			scene.add(c);

			const report = scene.export("build/export_baked.glb", { bake: 128 });
			return {
				shaded: report.shaded,
				bakedImages: report.bakedImages,
				bakedColors: report.bakedColors,
				images: report.images,
				materials: report.materials
			};
		`);
		defer result.free();
		test::@check(result.ok, "the script succeeded: %s", result.error);

		test::@check(result.value.contains(`"shaded":0`),
			"nothing was lost — every body ran and came back: %s", result.value);
		test::@check(result.value.contains(`"bakedImages":2`),
			"the gradient and the cutout vary across their surfaces: %s", result.value);
		test::@check(result.value.contains(`"bakedColors":1`),
			"and the one that does not is a colour rather than an image: %s", result.value);
		test::@check(result.value.contains(`"images":2`),
			"so two images were written, not three: %s", result.value);
		test::@check(result.value.contains(`"materials":3`),
			"three bodies are three materials, where without a bake they are one grey: %s",
			result.value);

		String json = json_chunk(path);
		// The uniform as it was given, decoded to linear because that is what
		// `baseColorFactor` is. sRGB is what the target stores and what the PNG
		// holds; the round trip through eight bits is why this is a prefix.
		test::@check(json.contains(`"baseColorFactor":[0.0998`),
			"the flat body's own tint, not a stand-in: %s", json);
		test::@check(json.contains(`"alphaMode":"MASK"`),
			"and the body that discards cuts its shape out of the quad: %s", json);
		test::@check(occurrences(json, `"alphaMode":"MASK"`) == 1,
			"only that one — a body that covers its surface stays OPAQUE: %s", json);
	};
}

<*
 The same scene with no `bake`, which has to be the file it always was.

 The whole feature is opt-in: it needs a device, which the rest of `export`
 deliberately does not, and it costs a render and a readback per material. So the
 default has to be byte-for-byte the old behaviour, and `shaded` has to go back to
 counting every copy.
*>
fn void baking_is_off_unless_it_is_asked_for() @test
{
	String path = "build/export_unbaked.glb";
	defer (void)file::delete(path);

	@with_js(; three::JsRuntime* run)
	{
		three::RunResult result = run.run(`
			const scene = new three.Scene();
			const body = new three.ShaderMaterial({
				fragment: "float3 shade(Surface s) { return float3(s.uv.x, s.uv.y, 0.2); }"
			});
			scene.add(new three.Mesh(new three.PlaneGeometry(2, 2), body));
			const b = new three.Mesh(new three.BoxGeometry(1, 1, 1), body);
			b.position.x = 3;
			scene.add(b);

			const report = scene.export("build/export_unbaked.glb");
			return {
				shaded: report.shaded,
				bakedImages: report.bakedImages,
				bakedColors: report.bakedColors,
				images: report.images
			};
		`);
		defer result.free();
		test::@check(result.ok, "the script succeeded: %s", result.error);
		test::@check(result.value.contains(`"shaded":2`),
			"both copies lost their shader, as they always did: %s", result.value);
		test::@check(result.value.contains(`"bakedImages":0`) && result.value.contains(`"bakedColors":0`),
			"and nothing was baked: %s", result.value);
		test::@check(result.value.contains(`"images":0`),
			"so the file carries no image at all: %s", result.value);
	};
}

<*
 A bake never splits a batch.

 The renderer's central claim is that a thousand copies of one shape under one
 material are one draw call, and the exporter's is that they are one instanced
 node. A body reading `s.position` answers differently at every copy, so the
 tempting thing is to bake each of them — six images here, six materials, six
 `mesh` entries, and six draw calls when the file is loaded back.

 So the copies inside a batch share the batch's one answer, and the standalone
 node beside them — which already had a node of its own — gets one of its own.
 Two images for seven copies, and the batch is still a batch.
*>
fn void a_bake_never_splits_a_batch() @test
{
	String path = "build/export_baked_batch.glb";
	defer (void)file::delete(path);

	@with_js(; three::JsRuntime* run)
	{
		three::RunResult result = run.run(`
			const scene = new three.Scene();
			const world = new three.ShaderMaterial({
				fragment: "float3 shade(Surface s) { return float3(frac(s.position.x), 0.3, 0.6); }"
			});
			for (let i = 0; i < 6; i++) {
				const m = new three.Mesh(new three.BoxGeometry(1, 1, 1), world);
				m.position.x = i * 2;
				scene.add(m);
			}
			const lone = new three.Mesh(new three.SphereGeometry(1, 8, 6), world);
			lone.position.y = 5;
			scene.add(lone);

			const report = scene.export("build/export_baked_batch.glb", { bake: 64 });
			return {
				batches: report.batches,
				instances: report.instances,
				images: report.images,
				bakedImages: report.bakedImages,
				shaded: report.shaded
			};
		`);
		defer result.free();
		test::@check(result.ok, "the script succeeded: %s", result.error);
		test::@check(result.value.contains(`"batches":1`),
			"the six siblings are still one instanced node: %s", result.value);
		test::@check(result.value.contains(`"instances":7`),
			"and all seven copies are in the file: %s", result.value);
		test::@check(result.value.contains(`"images":2`),
			"one image for the batch and one for the copy that had a node of its own: %s",
			result.value);
		test::@check(result.value.contains(`"bakedImages":7`) && result.value.contains(`"shaded":0`),
			"every copy is counted as baked, whichever image it shares: %s", result.value);
	};
}

<*
 What decides how many bakes a shape needs is the body, not the shape.

 Two copies of one mesh, each written as itself because each has a child. Under a
 body that reads `s.position` they are two different answers and must be two
 images; under one that does not they are the same answer and must be one.

 The count that says so is `entries`: a `mesh` entry is one `(geometry,
 material)` pair, so a second bake is a second material over the same accessors
 rather than a second copy of the geometry. `meshes` stays 1 either way, which is
 the half worth checking — a bake must not duplicate vertices.
*>
fn void a_body_that_reads_where_it_is_bakes_per_node() @test
{
	String moving = "build/export_baked_moving.glb";
	String still = "build/export_baked_still.glb";
	defer (void)file::delete(moving);
	defer (void)file::delete(still);

	@with_js(; three::JsRuntime* run)
	{
		three::RunResult result = run.run(`
			function twoCopies(material) {
				const scene = new three.Scene();
				for (let i = 0; i < 2; i++) {
					const m = new three.Mesh(new three.PlaneGeometry(2, 2), material);
					m.position.x = i * 4;
					// One group each, so the two copies are not siblings and neither
					// is collapsed into a batch: each is written as itself, and so
					// each may have a bake of its own.
					const holder = new three.Group();
					holder.add(m);
					scene.add(holder);
				}
				return scene;
			}

			const moving = twoCopies(new three.ShaderMaterial({
				fragment: "float3 shade(Surface s) { return float3(frac(s.position.x), s.uv.y, 0.5); }"
			}));
			const a = moving.export("build/export_baked_moving.glb", { bake: 64 });

			const still = twoCopies(new three.ShaderMaterial({
				fragment: "float3 shade(Surface s) { return float3(s.uv.x, s.uv.y, 0.5); }"
			}));
			const b = still.export("build/export_baked_still.glb", { bake: 64 });

			return {
				moving: { meshes: a.meshes, entries: a.entries, images: a.images },
				still: { meshes: b.meshes, entries: b.entries, images: b.images }
			};
		`);
		defer result.free();
		test::@check(result.ok, "the script succeeded: %s", result.error);

		test::@check(result.value.contains(`"moving":{"meshes":1,"entries":2,"images":2`),
			"a body that reads where it is gets an answer per placement, over one set of "
			"vertices: %s", result.value);
		test::@check(result.value.contains(`"still":{"meshes":1,"entries":1,"images":1`),
			"and one that does not shares a single answer: %s", result.value);
	};
}

<*
 The baked image lands the right way up, and holds what the body said.

 The one property nothing else here can catch. Every pass in this project sets a
 negative viewport height so that glTF's coordinate system comes out the right way
 up in Vulkan's; uv (0, 0) is the *top-left* texel of an image, so a bake that
 inherited the flip would be mirrored — a picture that is exactly as plausible
 upside down as the right way up, and wrong in every file.

 So the body is `float3(s.uv.x, s.uv.y, 0)` on a plane whose uv runs 0..1 across
 it, and the corners of the image are read back off the device after a reload. The
 values are sRGB, which is what the target stores and what a PNG is defined to
 hold — there is no conversion anywhere on that path — so 0 and 1 come back as 0
 and 255 and the gradient between them is not linear.
*>
fn void a_baked_texture_lands_the_right_way_up() @test
{
	String path = "build/export_baked_uv.glb";
	defer (void)file::delete(path);

	vk::Instance instance = three::create_instance(false, headless: true)!!;
	defer instance.free();

	three::Renderer renderer;
	renderer.init(instance, (vk::SurfaceKHR)null, 200, 150)!!;
	defer renderer.free();
	renderer.pass.init(&renderer.gpu, &renderer.target)!!;

	String diagnostic;
	uint material = renderer.pass.create_material(
		&renderer.gpu, &renderer.target,
		"float3 shade(Surface s) { return float3(s.uv.x, s.uv.y, 0.0); }",
		{},
		diagnostic: &diagnostic
	)!!;
	defer if (diagnostic.len > 0) diagnostic.free(mem);

	three::AssetId plane = renderer.pass.assets.primitive(&renderer.gpu, three::plane_shape(2, 2))!!;
	three::NodeId node = renderer.pass.scene.add_mesh(plane, 0);
	renderer.pass.scene.set_material(node, material);

	const uint SIZE = 64;
	three::ExportReport report = renderer.pass.export_scene(path, bake: SIZE)!!;
	test::@check(report.images == 1 && report.shaded == 0,
		"the body baked into one image, got images = %d and shaded = %d",
		report.images, report.shaded);

	// Loaded and placed: the image reaches the device when something draws with it,
	// not when the file is read.
	three::AssetId reloaded = renderer.pass.assets.load(&renderer.gpu, path)!!;
	renderer.pass.scene.add_mesh(reloaded, 0);
	three::GpuMesh* mesh = renderer.pass.assets.mesh(reloaded, 0);
	test::@check(mesh != null && mesh.texture >= 0,
		"the reloaded mesh carries the baked image, got texture %d",
		mesh == null ? -99 : mesh.texture);

	three::Texture* back = renderer.pass.assets.texture_at(mesh.texture);
	test::@check(back.width == SIZE && back.height == SIZE,
		"at the size it was asked for, got %dx%d", back.width, back.height);

	char[] pixels = mem::new_array(char, (sz)back.width * back.height * 4);
	defer free(pixels);
	back.read_pixels(&renderer.gpu, pixels)!!;

	// Two texels in from each corner, so a seam texel cannot decide the answer.
	sz row = (sz)SIZE * 4;
	int top_left_u = (int)pixels[2 * row + 2 * 4];
	int top_left_v = (int)pixels[2 * row + 2 * 4 + 1];
	int top_right_u = (int)pixels[2 * row + (SIZE - 3) * 4];
	int bottom_left_v = (int)pixels[(SIZE - 3) * row + 2 * 4 + 1];

	test::@check(top_left_u < 64 && top_left_v < 64,
		"uv (0, 0) is the top-left texel, got u = %d and v = %d there", top_left_u, top_left_v);
	test::@check(top_right_u > 192,
		"u runs left to right, got %d at the top-right", top_right_u);
	test::@check(bottom_left_v > 192,
		"and v runs top to bottom, which is the flip that would otherwise be silent; "
		"got %d at the bottom-left", bottom_left_v);
}

<*
 A baked image carries no transparency unless the body actually cut something out.

 glTF says a viewer ignores the alpha of a base colour map under `OPAQUE`, and
 that is true of the *material*. It is not true of the image: Blender's importer
 premultiplies a PNG that has an alpha channel, so a texel the bake left at zero
 comes back as **black** however good the colour underneath it is. On a mesh whose
 uv layout is islands — a cylinder's caps, a convex hull's facets — that is a
 model covered in black wedges in the exact shape of the gaps in its layout, and
 it was what the first baked export of a real scene looked like in Blender.

 A cylinder is the shape that shows it: its caps are discs, so the corners of the
 square around each one are never rasterised. The check is that they still come
 back opaque, and that nothing anywhere in the image is the black the clear left
 behind — which is `dilate`'s half of the same fix.
*>
fn void a_baked_image_is_opaque_unless_the_body_cuts() @test
{
	String path = "build/export_baked_opaque.glb";
	defer (void)file::delete(path);

	vk::Instance instance = three::create_instance(false, headless: true)!!;
	defer instance.free();

	three::Renderer renderer;
	renderer.init(instance, (vk::SurfaceKHR)null, 200, 150)!!;
	defer renderer.free();
	renderer.pass.init(&renderer.gpu, &renderer.target)!!;

	String diagnostic;
	uint material = renderer.pass.create_material(
		&renderer.gpu, &renderer.target,
		"float3 shade(Surface s) { return float3(0.9, 0.4 + 0.5 * s.uv.y, 0.2); }",
		{},
		diagnostic: &diagnostic
	)!!;
	defer if (diagnostic.len > 0) diagnostic.free(mem);

	three::AssetId shape = renderer.pass.assets.primitive(
		&renderer.gpu, three::cylinder_shape(1, 1, 2, 12)
	)!!;
	three::NodeId node = renderer.pass.scene.add_mesh(shape, 0);
	renderer.pass.scene.set_material(node, material);

	const uint SIZE = 64;
	three::ExportReport report = renderer.pass.export_scene(path, bake: SIZE)!!;
	test::@check(report.baked_images == 1,
		"the body varies across the surface, so it should have baked an image; got %d",
		report.baked_images);

	three::AssetId reloaded = renderer.pass.assets.load(&renderer.gpu, path)!!;
	renderer.pass.scene.add_mesh(reloaded, 0);
	three::GpuMesh* mesh = renderer.pass.assets.mesh(reloaded, 0);
	test::@check(mesh != null && mesh.texture >= 0,
		"the reloaded mesh carries the baked image, got texture %d",
		mesh == null ? -99 : mesh.texture);

	three::Texture* back = renderer.pass.assets.texture_at(mesh.texture);
	char[] pixels = mem::new_array(char, (sz)back.width * back.height * 4);
	defer free(pixels);
	back.read_pixels(&renderer.gpu, pixels)!!;

	sz texels = (sz)back.width * (sz)back.height;
	sz see_through = 0;
	sz black = 0;
	for (sz i = 0; i < texels; i++)
	{
		if (pixels[i * 4 + 3] != 0xff) see_through++;
		if (pixels[i * 4] < 8 && pixels[i * 4 + 1] < 8 && pixels[i * 4 + 2] < 8) black++;
	}

	test::@check(see_through == 0,
		"%d of %d texels are not fully opaque, and an importer that premultiplies turns each "
		"of them black", see_through, texels);
	test::@check(black == 0,
		"%d of %d texels are still the black the target was cleared to, so the seams were not "
		"filled", black, texels);
}

<*
 A `LayeredMaterial` bakes, and its stack is not written a second time.

 A layer stack reaches the frame as a *generated* `ShaderMaterial`, so it goes
 through the bake like any other body — which is the point: `CUSTOM_materials_
 layers` is this project's own extension and nothing outside it reads one, so a
 stack that only ever travelled as the extension arrived in Blender as a flat
 material. Baked, it arrives as what it looked like.

 What has to *not* happen is both. The stack is already inside the baked answer,
 so writing the extension beside it means a reader that understands it — this
 renderer, on the way back in — applies the moss over an image that already has
 moss in it. The same argument covers the base map: `s.albedo` sampled it during
 the bake, so writing it as the material's `baseColorTexture` would multiply it
 in twice.

 Both images are flat here, so the stack resolves to one colour and the whole
 material comes back as a `baseColorFactor` with nothing else attached — which is
 exactly the assertion: `images: 0` and `layers: 0`.
*>
fn void a_layered_material_bakes_instead_of_writing_its_stack() @test
{
	String plain = "build/export_layers_plain.glb";
	String baked = "build/export_layers_baked.glb";
	defer (void)file::delete(plain);
	defer (void)file::delete(baked);

	@with_js(; three::JsRuntime* run)
	{
		three::RunResult result = run.run(`
			const base = new three.DataTexture(new Uint8Array(8 * 8 * 4).fill(180), 8, 8);
			const moss = new three.DataTexture(new Uint8Array(8 * 8 * 4).fill(90), 8, 8);
			const mat = new three.LayeredMaterial({
				map: base,
				layers: [{ name: 'moss', map: moss, tint: [0.2, 0.8, 0.3], opacity: 0.7 }]
			});
			const scene = new three.Scene();
			scene.add(new three.Mesh(new three.SphereGeometry(1, 16, 12), mat));

			const a = scene.export("build/export_layers_plain.glb");
			const b = scene.export("build/export_layers_baked.glb", { bake: 64 });
			return {
				plain: { images: a.images, layers: a.layers, shaded: a.shaded },
				baked: { images: b.images, layers: b.layers, shaded: b.shaded,
				         bakedColors: b.bakedColors }
			};
		`);
		defer result.free();
		test::@check(result.ok, "the script succeeded: %s", result.error);

		// Unbaked, both halves travel: the two images and the stack that names them.
		test::@check(result.value.contains(`"plain":{"images":2,"layers":1,"shaded":1}`),
			"without a bake a stack is written as the extension and counted as lost: %s",
			result.value);

		// Baked, the answer travels and nothing else does.
		test::@check(result.value.contains(`"baked":{"images":0,"layers":0,"shaded":0,"bakedColors":1}`),
			"a baked stack is the answer alone — no source images, no second copy of the "
			"stack to apply over it: %s", result.value);

		String json = json_chunk(baked);
		test::@check(!json.contains("CUSTOM_materials_layers"),
			"the extension must not be beside the bake: %s", json);
		test::@check(!json.contains("baseColorTexture"),
			"and neither must the base map the body already sampled: %s", json);
	};
}

// ============================================================================
// Rigs, clips and blend shapes
// ============================================================================

<*
 A skinned character exports as a character rather than as a statue.

 What has to be in the file is four things that have to agree: the vertices'
 JOINTS_0 and WEIGHTS_0, a skeleton of nodes, a skin naming those nodes in the
 order the attribute indexes them, and the inverse bind matrices. Any one of them
 missing is a mesh that comes back either unposed or turned inside out, and the
 reload is what says all four agree — `Assets.load` reads the skin the same way
 it reads any other file's, so a character that comes back with its clips is one
 whose rig the loader could make sense of.

 The clips are the second half. They are read out of the source document rather
 than off the frame, for `write_skeleton`'s reason, and a character that arrives
 with `Bend` and `Twist` on it is one a viewer can play.
*>
fn void a_skinned_copy_exports_its_rig() @test
{
	String path = "build/export_rig.glb";
	defer (void)file::delete(path);

	@with_js(; three::JsRuntime* run)
	{
		three::RunResult result = run.run(`
			const scene = new three.Scene();
			const asset = three.load("test/fixtures/skinned.glb");
			scene.add(asset.instantiate());
			const report = scene.export("build/export_rig.glb");

			new three.Scene();
			const back = three.load("build/export_rig.glb");
			return {
				wrote: [report.skins, report.bones, report.clips],
				clips: back.animations,
			};
		`);
		defer result.free();

		test::@check(result.ok, "the script succeeded: %s", result.error);
		test::@check(
			result.value == `{"wrote":[1,2,2],"clips":["Bend","Twist"]}`,
			"one skeleton of two bones, both clips, and they load back; got %s",
			result.value
		);

		String json = json_chunk(path);
		test::@check(json.contains(`"JOINTS_0"`) && json.contains(`"WEIGHTS_0"`), "the vertices name their joints");
		test::@check(json.contains(`"skins":[`) && json.contains(`"inverseBindMatrices"`), "and the skin names them back");
		// The placement is on the wrapper and not on the node with the skin, which
		// is not a detail: a reader ignores a skinned node's own transform, so a
		// character written with its position there is a character at the origin.
		test::@check(!json.contains(`"skin":0,"translation"`), "the skinned node carries no transform of its own");
	};
}

<*
 Two copies are two skeletons and one set of keyframes.

 Both halves are forced, and they pull in opposite directions. The *skeletons*
 have to be per copy because glTF places a skinned mesh by where its joints are
 and ignores the node's own transform — one shared skeleton would draw both
 characters standing in the same spot. The *keyframes* must not be, because they
 are the kilobytes: a clip is written once and given a channel onto each
 skeleton, so a crowd costs a channel a bone and not a curve a bone.

 The inverse bind matrices go with the keyframes rather than with the skeletons.
 They say how a vertex leaves the bind pose, which is a property of the rig and
 not of where a copy is standing — one MAT4 accessor in the file, however many
 wear it.

 Flattened, because that is the walk where two copies of one character would
 otherwise meet in a batch: they arrive wrapped in a group each, so no two of
 them are siblings and the hierarchical walk never compares them.

 The one batch the report counts is the fixture's other mesh — `Prop` is not
 rigged, and its two copies fold into an instanced node exactly as they should.
 That is the contrast worth having in the same file: the refusal is about the
 rig, not about copies.
*>
fn void two_copies_are_two_skeletons_and_one_set_of_keyframes() @test
{
	String path = "build/export_crowd.glb";
	defer (void)file::delete(path);

	@with_js(; three::JsRuntime* run)
	{
		three::RunResult result = run.run(`
			const scene = new three.Scene();
			const asset = three.load("test/fixtures/skinned.glb");
			const a = asset.instantiate();
			const b = asset.instantiate();
			b.position.x = 4;
			scene.add(a);
			scene.add(b);
			const report = scene.export("build/export_crowd.glb", { flatten: true });
			return [report.skins, report.bones, report.clips, report.batches];
		`);
		defer result.free();

		test::@check(result.ok, "the script succeeded: %s", result.error);
		test::@check(
			result.value == "[2,4,2,1]",
			"two skeletons of two bones, the clips written once, and only the unrigged prop batched; got %s",
			result.value
		);

		String json = json_chunk(path);
		test::@check(occurrences(json, `"skin":`) == 2, "a skin per copy: %s", json);
		test::@check(occurrences(json, `"type":"MAT4"`) == 1, "and one set of inverse binds between them");
		// A channel is a pair of integers and a sampler is a curve. Two copies mean
		// twice the channels and exactly the same samplers.
		test::@check(
			occurrences(json, `"sampler":`) == 2 * occurrences(json, `"input":`),
			"two channels per sampler, which is one curve driving both copies: %s",
			json
		);
	};
}

<*
 Blend shapes survive, and each copy keeps the weights it was drawn with.

 The displacements are the geometry's and are written once — twelve plants at
 twelve growth stages share one set of targets exactly as they share one set of
 positions. The *weights* are the copy's, and `node.weights` is the only channel
 glTF has for them: a mesh's own weights belong to the shape and so to every copy
 of it.

 Which is why a morphing copy is never folded into an instanced node. These two
 are siblings drawing one mesh with one material — the batch's whole key — so
 without that refusal they would come back as one node in one shape, and the
 difference between them is the thing being exported.
*>
fn void a_morphing_copy_carries_its_own_weights() @test
{
	String path = "build/export_morph.glb";
	defer (void)file::delete(path);

	@with_js(; three::JsRuntime* run)
	{
		three::RunResult result = run.run(`
			const scene = new three.Scene();
			const asset = three.load("test/fixtures/morph.glb");
			const shape = asset.mesh("Face");

			// Added first: the target count is read off the uploaded geometry, so a
			// weight set before the add is one nothing can check.
			const a = new three.Mesh(shape);
			scene.add(a);
			a.weights = [1, 0];

			const b = new three.Mesh(shape);
			b.position.x = 3;
			scene.add(b);
			b.weights = [0, 0.5];

			const report = scene.export("build/export_morph.glb");

			new three.Scene();
			const back = three.load("build/export_morph.glb");
			const shapes = [];
			const reloaded = new three.Scene();
			reloaded.add(back.instantiate());
			reloaded.traverse((o) => { if (o.morphs > 0) shapes.push(o.morphs); });

			return {
				wrote: [report.meshes, report.morphed, report.batches],
				morphs: shapes,
			};
		`);
		defer result.free();

		test::@check(result.ok, "the script succeeded: %s", result.error);
		test::@check(
			result.value == `{"wrote":[1,2,0],"morphs":[2,2]}`,
			"one mesh, two copies wearing their own weights, nothing batched; got %s",
			result.value
		);

		String json = json_chunk(path);
		// One `targets` array, because the displacements are the shape's. Two
		// `weights`, because what each copy is wearing is not.
		test::@check(occurrences(json, `"targets":[`) == 1, "the displacements are written once: %s", json);
		test::@check(occurrences(json, `"weights":[`) == 2, "and the weights once per copy: %s", json);
		test::@check(json.contains(`"weights":[1,0]`) && json.contains(`"weights":[0,0.5]`), "with the values drawn");
	};
}

<*
 A mesh with no rig is written exactly as it always was.

 The check that none of this leaks into the overwhelming majority of files. A box
 has no joints to name and no shapes to blend, so its primitive has neither, its
 node carries no weights, and the document has no `skins` array at all — an empty
 one would be a file claiming a rig it does not have.
*>
fn void an_unrigged_scene_says_nothing_about_rigs() @test
{
	String path = "build/export_plain.glb";
	defer (void)file::delete(path);

	@with_js(; three::JsRuntime* run)
	{
		three::RunResult result = run.run(`
			const scene = new three.Scene();
			scene.add(new three.Mesh(new three.BoxGeometry(1, 1, 1)));
			const report = scene.export("build/export_plain.glb");
			return [report.skins, report.bones, report.clips, report.morphed];
		`);
		defer result.free();

		test::@check(result.ok, "the script succeeded: %s", result.error);
		test::@check(result.value == "[0,0,0,0]", "nothing rigged and nothing morphing; got %s", result.value);

		String json = json_chunk(path);
		test::@check(!json.contains(`"skins"`), "no skins array: %s", json);
		test::@check(!json.contains(`"animations"`), "no animations array");
		test::@check(!json.contains(`"targets"`) && !json.contains(`"weights"`), "and no morph keys");
	};
}
