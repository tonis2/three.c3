<*
 Merging — `src/scene/merge.c3` — the opposite of `split.c3`: every mesh in a
 subtree, or an explicit array of meshes, concatenated into one asset with
 each one's transform baked into its vertices.

	`c3c test --trust=full --test-noleak --test-filter three_tests::merge`

 Two levels, `extrude_test.c3`'s and `split_test.c3`'s own split: the host half
 needs no JavaScript, so it is proved directly against `Assets.merge` with
 fixtures built the way `split_test.c3`'s `quad` is — small, disjoint, and
 exact enough that a wrong transform or a dropped stream shows up as a specific
 wrong number rather than a picture that merely looks off. The frame, the
 material rule and the two spellings live in `prelude.js` and are proved
 through `JsRuntime.run`, the way `extrude_test.c3`'s second half proves
 `ExtrudeGeometry`'s script-facing rules.

 The round trip this suite cares most about is the same one `split_test.c3`
 pins the other direction: merge two quads, split the result, and get the two
 quads back. If `Assets.merge` ever welded a vertex it should not have, or
 `Assets.read_geometry`'s `has_merged` branch ever fell through to the hull
 fallback, that round trip is the first thing to notice — a welded seam turns
 two pieces into one on the way back out, and a hull fallback replaces real
 uvs with a projection that `a_merged_mesh_exports_and_reloads_...` would still
 pass, because a hull's projection is real triangles too. Only the split
 round trip actually depends on the vertices staying exactly the ones that
 went in.
*>
module three_tests::merge;

import three;
import three_tests::device;
import vk;
import std::core::test;
import std::collections::list;
import std::math;
import std::math::vector;
import std::math::matrix;
import std::io::file;

alias Vec3 = float[<3>];
alias Vec4 = float[<4>];

// ============================================================================
// Host level — no JavaScript
// ============================================================================

macro @with_pass(; @body(three::Renderer* renderer))
{
	three::Renderer* renderer = device::borrow(200, 150);
	defer device::release();

	@body(renderer);
}

<*
 A quad at `x`, in the xy plane facing +z, as four vertices and two triangles
 — `split_test.c3`'s fixture, minus the touching-corner and colour arguments
 this suite has no use for. One quad is one connected component, which is
 what makes "merge two, split, get two back" a test of concatenation rather
 than of `split_mesh`'s own union-find.
*>
fn void quad(three::GeometryBuilder* out, float x)
{
	Vec3[4] corners = {
		{ x - 0.5, -0.5, 0 }, { x + 0.5, -0.5, 0 }, { x + 0.5, 0.5, 0 }, { x - 0.5, 0.5, 0 },
	};
	uint first = (uint)out.positions.len();
	foreach (i, corner : corners)
	{
		out.positions.push(corner);
		out.normals.push({ 0, 0, 1 });
		out.uvs.push({ (float)i / 4.0f, x });
	}
	out.triangle(first, first + 1, first + 2);
	out.triangle(first, first + 2, first + 3);
}

fn three::AssetId built_from(three::Renderer* renderer, String key, three::GeometryBuilder* geometry)
{
	return renderer.pass.assets.upload_built(&renderer.gpu, key, "piece", geometry)!!;
}

const Vec4 WHITE = { 1, 1, 1, 1 };

<*
 Two disjoint quads merge into one mesh with both their vertex counts and
 neither welded to the other, and splitting the result gives the two quads
 straight back — the round trip the header calls out.
*>
fn void two_disjoint_quads_merge_into_one_mesh_and_split_back_apart() @test
{
	@with_pass(; three::Renderer* renderer)
	{
		three::Assets* assets = &renderer.pass.assets;

		three::GeometryBuilder left;
		left.init();
		defer left.free();
		quad(&left, -2.0);
		three::AssetId left_asset = built_from(renderer, "<merge test left>", &left);

		three::GeometryBuilder right;
		right.init();
		defer right.free();
		quad(&right, 0.0);
		three::AssetId right_asset = built_from(renderer, "<merge test right>", &right);

		// The right quad is built at x=0 and carried to x=4 by its matrix, so a
		// bug that forgot the matrix entirely (an identity everywhere) would
		// still merge two quads — it would just merge them on top of each
		// other, which the bounds check below catches and the vertex count
		// would not.
		three::MergeInput[2] inputs = {
			{ .asset = left_asset, .mesh = 0, .matrix = matrix::IDENTITY4{float}, .color = WHITE },
			{
				.asset = right_asset,
				.mesh = 0,
				.matrix = matrix::IDENTITY4{float}.translate({ 4, 0, 0 }),
				.color = WHITE,
			},
		};

		uint failed_at = 0;
		three::AssetId merged = assets.merge(&renderer.gpu, inputs[..], &failed_at)!!;

		three::GpuMesh* mesh = assets.mesh(merged, 0);
		test::@check(mesh != null, "the merged asset has no mesh 0");
		if (mesh == null) return;
		test::@check(mesh.vertex_count == 8, "merged vertex count is %d, expected 8", mesh.vertex_count);
		test::@check(mesh.index_count == 12, "merged index count is %d, expected 12", mesh.index_count);
		test::@check(
			math::abs(mesh.bounds.min.x - (-2.5f)) < 1e-4f, "merged min.x is %f, expected -2.5", mesh.bounds.min.x
		);
		test::@check(
			math::abs(mesh.bounds.max.x - 4.5f) < 1e-4f, "merged max.x is %f, expected 4.5", mesh.bounds.max.x
		);

		List{three::MeshPiece} pieces;
		pieces.init(mem, 4);
		defer pieces.free();
		uint count = assets.split_mesh(&renderer.gpu, merged, 0, &pieces)!!;
		test::@check(count == 2, "the merged mesh split into %d pieces, expected 2", count);
		test::@check(pieces.len() == 2, "and %d were appended", pieces.len());

		float[2] centres;
		foreach (i, piece : pieces)
		{
			three::GpuMesh* piece_mesh = assets.mesh(piece.asset, piece.mesh);
			test::@check(piece_mesh != null, "piece %d has no mesh", i);
			if (piece_mesh == null) continue;
			test::@check(
				piece_mesh.vertex_count == 4, "piece %d has %d vertices, expected 4", i, piece_mesh.vertex_count
			);
			test::@check(
				piece_mesh.index_count == 6, "piece %d has %d indices, expected 6", i, piece_mesh.index_count
			);
			centres[i] = (piece_mesh.bounds.min.x + piece_mesh.bounds.max.x) * 0.5f;
		}
		test::@check(
			math::abs(centres[0] - (-2.0f)) < 1e-4f, "piece 0 is centred at %f, expected -2", centres[0]
		);
		test::@check(math::abs(centres[1] - 4.0f) < 1e-4f, "piece 1 is centred at %f, expected 4", centres[1]);
	};
}

<*
 The dedup key: the same inputs merged twice answer with the same asset, and
 moving one of them answers with a different one — `merge_key` hashing what
 actually varies the output, `convex_key`'s own argument.
*>
fn void merging_the_same_inputs_twice_is_one_asset_and_a_moved_one_is_another() @test
{
	@with_pass(; three::Renderer* renderer)
	{
		three::Assets* assets = &renderer.pass.assets;

		three::GeometryBuilder geometry;
		geometry.init();
		defer geometry.free();
		quad(&geometry, 0.0);
		three::AssetId source = built_from(renderer, "<merge dedup source>", &geometry);

		three::MergeInput[1] first_inputs = {
			{ .asset = source, .mesh = 0, .matrix = matrix::IDENTITY4{float}, .color = WHITE },
		};
		uint failed_at = 0;
		three::AssetId first = assets.merge(&renderer.gpu, first_inputs[..], &failed_at)!!;
		three::AssetId second = assets.merge(&renderer.gpu, first_inputs[..], &failed_at)!!;
		test::@check(
			first.index == second.index && first.generation == second.generation,
			"merging the same input twice gave two different assets: %d/%d and %d/%d",
			first.index,
			first.generation,
			second.index,
			second.generation
		);

		three::MergeInput[1] moved_inputs = {
			{
				.asset = source,
				.mesh = 0,
				.matrix = matrix::IDENTITY4{float}.translate({ 1, 0, 0 }),
				.color = WHITE,
			},
		};
		three::AssetId moved = assets.merge(&renderer.gpu, moved_inputs[..], &failed_at)!!;
		test::@check(
			!(moved.index == first.index && moved.generation == first.generation),
			"a moved input answered with the same asset as the original"
		);
	};
}

<*
 A mirrored input (a negative-determinant matrix) has its triangles rewound
 along with its normals, so the two keep agreeing — every merged triangle's
 geometric winding and its stored normal point the same way.
*>
fn void a_mirrored_input_flips_winding_so_normals_agree_with_it() @test
{
	@with_pass(; three::Renderer* renderer)
	{
		three::Assets* assets = &renderer.pass.assets;

		three::GeometryBuilder geometry;
		geometry.init();
		defer geometry.free();
		quad(&geometry, 0.0);
		three::AssetId source = built_from(renderer, "<merge mirror source>", &geometry);

		three::MergeInput[1] inputs = {
			{
				.asset = source,
				.mesh = 0,
				.matrix = matrix::IDENTITY4{float}.scale({ -1, 1, 1 }),
				.color = WHITE,
			},
		};
		uint failed_at = 0;
		three::AssetId merged = assets.merge(&renderer.gpu, inputs[..], &failed_at)!!;

		three::GeometryBuilder read;
		read.init();
		defer read.free();
		test::@check(assets.read_geometry(merged, 0, &read), "could not read the mirrored merge back");

		sz triangles = read.indices.len() / 3;
		test::@check(triangles > 0, "the mirrored merge produced no triangles");
		for (sz t = 0; t < triangles; t++)
		{
			Vec3 a = read.positions[read.indices[t * 3]];
			Vec3 b = read.positions[read.indices[t * 3 + 1]];
			Vec3 c = read.positions[read.indices[t * 3 + 2]];
			Vec3 geometric = (b - a).cross(c - a);
			Vec3 stored = read.normals[read.indices[t * 3]];
			test::@check(
				geometric.dot(stored) > 0, "triangle %d's winding disagrees with its stored normal", t
			);
		}
	};
}

<*
 A line mesh has no triangles to concatenate, and says so — the same refusal
 `split_test.c3`'s `a_line_mesh_cannot_be_split` pins, and `failed_at` names
 the one input that caused it.
*>
fn void a_line_mesh_cannot_be_merged() @test
{
	@with_pass(; three::Renderer* renderer)
	{
		three::Assets* assets = &renderer.pass.assets;
		three::AssetId box = assets.lines(&renderer.gpu, { .kind = three::LineKind.BOX })!!;

		three::MergeInput[1] inputs = {
			{ .asset = box, .mesh = 0, .matrix = matrix::IDENTITY4{float}, .color = WHITE },
		};
		uint failed_at = 99;
		fault why = @catch(assets.merge(&renderer.gpu, inputs[..], &failed_at));
		test::@check(
			why == three::MESH_CANNOT_BE_MERGED, "merging a line mesh gave %s, not MESH_CANNOT_BE_MERGED", why
		);
		test::@check(failed_at == 0, "failed_at is %d, expected 0", failed_at);
	};
}

<*
 Two quads at the default white carry no colour stream at all — the same
 answer an ordinary untextured mesh gives, and the optimisation `Assets.merge`
 makes over always writing one.
*>
fn void an_untinted_merge_of_untinted_quads_carries_no_colour_stream() @test
{
	@with_pass(; three::Renderer* renderer)
	{
		three::Assets* assets = &renderer.pass.assets;

		three::GeometryBuilder a;
		a.init();
		defer a.free();
		quad(&a, -1.0);
		three::AssetId asset_a = built_from(renderer, "<merge colour a>", &a);

		three::GeometryBuilder b;
		b.init();
		defer b.free();
		quad(&b, 1.0);
		three::AssetId asset_b = built_from(renderer, "<merge colour b>", &b);

		three::MergeInput[2] inputs = {
			{ .asset = asset_a, .mesh = 0, .matrix = matrix::IDENTITY4{float}, .color = WHITE },
			{ .asset = asset_b, .mesh = 0, .matrix = matrix::IDENTITY4{float}, .color = WHITE },
		};
		uint failed_at = 0;
		three::AssetId merged = assets.merge(&renderer.gpu, inputs[..], &failed_at)!!;
		three::GpuMesh* mesh = assets.mesh(merged, 0);
		test::@check(mesh != null, "the merged asset has no mesh 0");
		if (mesh != null)
		{
			test::@check(!mesh.has_colors, "an untinted merge of untinted quads carries a colour stream");
		}
	};
}

<*
 One tinted input's colour is decoded the way the shader decodes `mesh.color`
 and baked into that quad's share of the merged vertex colours; the other
 quad, at the default white, gets the identity colour rather than leaving the
 stream short — `Assets.merge`'s header explains why a short stream is not an
 option once one input needs the attribute at all.
*>
fn void a_tinted_input_bakes_its_colour_into_the_merged_vertex_stream() @test
{
	@with_pass(; three::Renderer* renderer)
	{
		three::Assets* assets = &renderer.pass.assets;

		three::GeometryBuilder a;
		a.init();
		defer a.free();
		quad(&a, -1.0);
		three::AssetId asset_a = built_from(renderer, "<merge tint a>", &a);

		three::GeometryBuilder b;
		b.init();
		defer b.free();
		quad(&b, 1.0);
		three::AssetId asset_b = built_from(renderer, "<merge tint b>", &b);

		// Pure red and pure white both decode to themselves — srgb_to_linear(0)
		// is 0 and srgb_to_linear(1) is 1 at the curve's endpoints — so the
		// expected numbers below are exact rather than a piecewise curve away
		// from the input.
		three::MergeInput[2] inputs = {
			{ .asset = asset_a, .mesh = 0, .matrix = matrix::IDENTITY4{float}, .color = { 1, 0, 0, 1 } },
			{ .asset = asset_b, .mesh = 0, .matrix = matrix::IDENTITY4{float}, .color = WHITE },
		};
		uint failed_at = 0;
		three::AssetId merged = assets.merge(&renderer.gpu, inputs[..], &failed_at)!!;
		three::GpuMesh* mesh = assets.mesh(merged, 0);
		test::@check(mesh != null && mesh.has_colors, "the tinted merge carries no colour stream");

		three::GeometryBuilder read;
		read.init();
		defer read.free();
		test::@check(assets.read_geometry(merged, 0, &read), "could not read the tinted merge back");
		test::@check(read.colors.len() == 8, "read %d colours, expected 8", read.colors.len());

		for (sz i = 0; i < 4; i++)
		{
			Vec4 c = read.colors[i];
			test::@check(
				math::abs(c.x - 1.0f) < 1e-5f && math::abs(c.y) < 1e-5f && math::abs(c.z) < 1e-5f
					&& math::abs(c.w - 1.0f) < 1e-5f,
				"quad a vertex %d colour is (%f,%f,%f,%f), expected (1,0,0,1)",
				i,
				c.x,
				c.y,
				c.z,
				c.w
			);
		}
		for (sz i = 4; i < 8; i++)
		{
			Vec4 c = read.colors[i];
			test::@check(
				math::abs(c.x - 1.0f) < 1e-5f && math::abs(c.y - 1.0f) < 1e-5f && math::abs(c.z - 1.0f) < 1e-5f
					&& math::abs(c.w - 1.0f) < 1e-5f,
				"quad b vertex %d colour is (%f,%f,%f,%f), expected (1,1,1,1)",
				i,
				c.x,
				c.y,
				c.z,
				c.w
			);
		}
	};
}

// ============================================================================
// JavaScript level — three.merge, the two spellings and the refusals
// ============================================================================

macro @with_js(; @body(three::JsRuntime* run))
{
	three::Renderer* renderer = device::borrow(200, 150);
	defer device::release();

	three::JsRuntime runtime;
	runtime.open(&renderer.pass, renderer)!!;
	defer runtime.close();

	@body(&runtime);
}

<*
 A box translated by (2, 0, 0) and a box turned a quarter turn about y, both
 under one Group: `three.merge(group)` gives back a geometry whose bounds
 agree with `group.boundsInParent()` — the two independent ways this project
 composes a local transform, JavaScript's `transformBox` and the host's
 baked vertices, landing on the same box — carrying 2 meshes and the 24
 triangles two boxes have between them, and a Mesh built over it draws as
 the one instance, one draw call `scene.stats()` promised.
*>
fn void a_translated_and_a_rotated_box_merge_to_the_groups_own_bounds_and_draw_as_one_instance() @test
{
	@with_js(; three::JsRuntime* run)
	{
		three::RunResult result = run.run(`
			const group = new three.Group();
			const a = new three.Mesh(new three.BoxGeometry(1, 1, 1));
			a.position.set(2, 0, 0);
			const b = new three.Mesh(new three.BoxGeometry(1, 1, 1));
			b.rotation.y = Math.PI / 2;
			group.add(a);
			group.add(b);

			const box = group.boundsInParent();
			const merged = three.merge(group);

			const near = (x, y) => Math.abs(x - y) < 1e-5;
			const boundsMatch = near(box.min.x, merged.bounds.min.x) && near(box.min.y, merged.bounds.min.y)
				&& near(box.min.z, merged.bounds.min.z) && near(box.max.x, merged.bounds.max.x)
				&& near(box.max.y, merged.bounds.max.y) && near(box.max.z, merged.bounds.max.z);

			const scene = new three.Scene();
			scene.add(new three.Mesh(merged, new three.MeshLambertMaterial()));
			const stats = three.stats();

			return {
				boundsMatch,
				meshes: merged.parameters.meshes,
				triangles: merged.parameters.triangles,
				drawCalls: stats.drawCalls,
				uniqueMeshes: stats.uniqueMeshes,
				instances: stats.instances,
			};
		`);
		defer result.free();

		test::@check(result.ok, "the script succeeded: %s", result.error);
		test::@check(result.value.contains(`"boundsMatch":true`), "the bounds did not agree: %s", result.value);
		test::@check(result.value.contains(`"meshes":2`), "expected parameters.meshes 2: %s", result.value);
		test::@check(result.value.contains(`"triangles":24`), "expected parameters.triangles 24: %s", result.value);
		test::@check(result.value.contains(`"drawCalls":1`), "expected 1 draw call: %s", result.value);
		test::@check(result.value.contains(`"uniqueMeshes":1`), "expected 1 unique mesh: %s", result.value);
		test::@check(result.value.contains(`"instances":1`), "expected 1 instance: %s", result.value);
	};
}

<*
 The same group merged twice is the same asset; a group whose child moved
 first is a different one — `three.merge`'s own dedup, proved through the
 script surface rather than against `Assets.merge` directly.
*>
fn void merging_the_same_group_twice_is_one_asset_and_a_moved_child_is_another() @test
{
	@with_js(; three::JsRuntime* run)
	{
		three::RunResult result = run.run(`
			function buildGroup(secondX) {
				const group = new three.Group();
				const a = new three.Mesh(new three.BoxGeometry(1, 1, 1));
				const b = new three.Mesh(new three.BoxGeometry(1, 1, 1));
				b.position.set(secondX, 0, 0);
				group.add(a);
				group.add(b);
				return group;
			}

			const firstMerge = three.merge(buildGroup(2));
			const secondMerge = three.merge(buildGroup(2));
			const thirdMerge = three.merge(buildGroup(3));

			return {
				sameAsset: firstMerge.asset === secondMerge.asset
					&& firstMerge.assetGeneration === secondMerge.assetGeneration,
				movedIsDifferent: !(firstMerge.asset === thirdMerge.asset
					&& firstMerge.assetGeneration === thirdMerge.assetGeneration),
			};
		`);
		defer result.free();

		test::@check(result.ok, "the script succeeded: %s", result.error);
		test::@check(
			result.value.contains(`"sameAsset":true`), "two identical groups did not share an asset: %s", result.value
		);
		test::@check(
			result.value.contains(`"movedIsDifferent":true`),
			"a group with a moved child answered with the original asset: %s",
			result.value
		);
	};
}

<*
 Colour is baked into the merged vertex stream, not layered over shared
 geometry the way `mesh.color` is over an ordinary draw — so it has to be
 part of the dedup key, or a second merge with a different tint would
 silently draw the first tint's bake under the second's name. Retinting a
 child, merging again, and putting the tint back all answer with the asset
 the colour in hand actually bakes to.
*>
fn void a_different_tint_is_a_different_asset_and_the_original_tint_is_the_original_asset() @test
{
	@with_js(; three::JsRuntime* run)
	{
		three::RunResult result = run.run(`
			const group = new three.Group();
			const a = new three.Mesh(new three.BoxGeometry(1, 1, 1));
			const b = new three.Mesh(new three.BoxGeometry(1, 1, 1));
			b.position.set(2, 0, 0);
			group.add(a);
			group.add(b);

			const originalMerge = three.merge(group);

			b.color = [1, 0, 0, 1];
			const tintedMerge = three.merge(group);

			b.color = [1, 1, 1, 1];
			const revertedMerge = three.merge(group);

			return {
				tintedIsDifferent: !(originalMerge.asset === tintedMerge.asset
					&& originalMerge.assetGeneration === tintedMerge.assetGeneration),
				revertedIsOriginal: originalMerge.asset === revertedMerge.asset
					&& originalMerge.assetGeneration === revertedMerge.assetGeneration,
			};
		`);
		defer result.free();

		test::@check(result.ok, "the script succeeded: %s", result.error);
		test::@check(
			result.value.contains(`"tintedIsDifferent":true`),
			"a retinted child answered with the untinted merge's asset: %s",
			result.value
		);
		test::@check(
			result.value.contains(`"revertedIsOriginal":true`),
			"putting the original colour back did not answer with the original asset: %s",
			result.value
		);
	};
}

<*
 A scene holding one merged mesh exports and reloads with the same triangle
 and vertex counts the merge itself reports, and the reloaded mesh still has
 normals and uvs — `Assets.read_geometry`'s `has_merged` branch doing its
 job instead of the hull fallback's averaged normals and projected uvs.
 `has_normals`/`has_uvs` are not observable from JavaScript, so this reaches
 past `RunResult` into the host `Assets` table the script and the check
 share, the way the task's own instructions anticipate.
*>
fn void a_merged_mesh_exports_and_reloads_with_matching_counts_and_keeps_normals_and_uvs() @test
{
	three::Renderer* renderer = device::borrow(200, 150);
	defer device::release();

	three::JsRuntime runtime;
	runtime.open(&renderer.pass, renderer)!!;
	defer runtime.close();

	String path = "build/export_merge_test.glb";
	defer (void)file::delete(path);

	three::RunResult result = runtime.run(`
		const group = new three.Group();
		const a = new three.Mesh(new three.BoxGeometry(1, 1, 1));
		a.position.set(2, 0, 0);
		const b = new three.Mesh(new three.BoxGeometry(1, 1, 1));
		group.add(a);
		group.add(b);
		const merged = three.merge(group);

		const scene = new three.Scene();
		scene.add(new three.Mesh(merged, new three.MeshLambertMaterial()));
		scene.export('build/export_merge_test.glb');

		new three.Scene();
		const asset = three.load('build/export_merge_test.glb');
		const reloaded = new three.Scene();
		reloaded.add(asset.instantiate());
		const ref = asset.meshAt(0);
		const stats = three.stats();

		return [
			ref.asset, ref.assetGeneration,
			merged.parameters.triangles, merged.parameters.meshes,
			stats.triangles, stats.vertices,
		];
	`);
	defer result.free();

	test::@check(result.ok, "the script succeeded: %s", result.error);
	if (!result.ok) return;

	String inner = result.value[1..result.value.len - 2];
	String[] parts = inner.tsplit(",");
	test::@check(parts.len == 6, "expected 6 numbers back, got %d: %s", parts.len, result.value);
	if (parts.len != 6) return;

	uint reloaded_index = (uint)(parts[0].to_int() ?? -1);
	uint reloaded_generation = (uint)(parts[1].to_int() ?? -1);
	int merged_triangles = parts[2].to_int() ?? -1;
	int merged_meshes = parts[3].to_int() ?? -1;
	int after_triangles = parts[4].to_int() ?? -1;
	int after_vertices = parts[5].to_int() ?? -1;

	test::@check(merged_meshes == 2, "expected 2 meshes merged, got %d", merged_meshes);
	test::@check(merged_triangles == 24, "expected 24 triangles merged, got %d", merged_triangles);
	test::@check(
		after_triangles == merged_triangles,
		"the reload has %d triangles, the merge had %d",
		after_triangles,
		merged_triangles
	);
	test::@check(after_vertices == 48, "the reload has %d vertices, expected 48", after_vertices);

	three::AssetId reloaded_id = { .index = reloaded_index, .generation = reloaded_generation };
	three::GpuMesh* reloaded_mesh = renderer.pass.assets.mesh(reloaded_id, 0);
	test::@check(reloaded_mesh != null, "the reloaded asset has no mesh 0");
	if (reloaded_mesh == null) return;

	test::@check(reloaded_mesh.vertex_count == 48, "reloaded vertex count is %d, expected 48", reloaded_mesh.vertex_count);
	test::@check(reloaded_mesh.has_normals, "the reloaded merged mesh lost its normals");
	test::@check(reloaded_mesh.has_uvs, "the reloaded merged mesh lost its uvs");
}

<*
 The refusals: two materials, naming both; a helper-only subtree, "nothing to
 merge"; the array spelling given two meshes with different parents; and two
 meshes disagreeing about `variant`.
*>
fn void merge_refuses_two_materials_a_helper_only_subtree_two_parents_and_differing_variants() @test
{
	@with_js(; three::JsRuntime* run)
	{
		three::RunResult result = run.run(`
			const refuse = (fn) => {
				try { fn(); return 'no throw'; }
				catch (e) { return e.constructor.name + ': ' + e.message; }
			};

			const twoMaterials = refuse(() => {
				const group = new three.Group();
				const a = new three.Mesh(new three.BoxGeometry(1, 1, 1), new three.MeshLambertMaterial());
				a.name = 'wallA';
				const b = new three.Mesh(new three.BoxGeometry(1, 1, 1), new three.MeshLambertMaterial());
				b.name = 'wallB';
				b.position.set(2, 0, 0);
				group.add(a);
				group.add(b);
				return three.merge(group);
			});

			const helperOnly = refuse(() => {
				const group = new three.Group();
				group.add(new three.AxesHelper(1));
				return three.merge(group);
			});

			const twoParents = refuse(() => {
				const p1 = new three.Group();
				const p2 = new three.Group();
				const a = new three.Mesh(new three.BoxGeometry(1, 1, 1));
				const b = new three.Mesh(new three.BoxGeometry(1, 1, 1));
				p1.add(a);
				p2.add(b);
				return three.merge([a, b]);
			});

			const material = new three.ShaderMaterial({
				fragment: 'float3 shade(Surface s) { return s.albedo; }',
				variants: 2,
			});
			const differingVariant = refuse(() => {
				const group = new three.Group();
				const a = new three.Mesh(new three.BoxGeometry(1, 1, 1), material);
				const b = new three.Mesh(new three.BoxGeometry(1, 1, 1), material);
				b.position.set(2, 0, 0);
				b.variant = 1;
				group.add(a);
				group.add(b);
				return three.merge(group);
			});

			return { twoMaterials, helperOnly, twoParents, differingVariant };
		`);
		defer result.free();

		test::@check(result.ok, "the script succeeded: %s", result.error);
		test::@check(
			result.value.contains(`"twoMaterials":"TypeError`) && result.value.contains("wallA")
				&& result.value.contains("wallB"),
			"two materials did not throw naming both: %s",
			result.value
		);
		test::@check(
			result.value.contains(`"helperOnly":"Error: three.merge(...): nothing to merge`),
			"a helper-only subtree did not answer 'nothing to merge': %s",
			result.value
		);
		test::@check(
			result.value.contains(`"twoParents":"TypeError`), "two parents in the array form did not throw: %s", result.value
		);
		test::@check(
			result.value.contains(`"differingVariant":"TypeError`), "a differing variant did not throw: %s", result.value
		);
	};
}
