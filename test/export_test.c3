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
		test::@check(
			declared.contains(`"extensionsUsed":["EXT_mesh_gpu_instancing"]`),
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
			// Two nodes: the root, and the one instanced node under it. Nine nodes
			// went in — a yard, four shelves and four boxes.
			result.value == `{"batches":1,"nodes":2,"placed":true,"yard":true}`,
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
			result.value == `{"same":[10,10,10],"batches":[0,0,0],"text":"scene.export options.flatten is true or false","object":"scene.export(path, options) wants an object for its options, like { flatten: true }"}`,
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
