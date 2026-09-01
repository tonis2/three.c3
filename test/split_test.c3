<*
 Cutting a merged mesh into its connected components — `src/scene/split.c3`.

 The fixtures are built here rather than loaded, because what these check is a
 property of the *index buffer* and a `.glb` on disk would put a parser between
 the claim and the evidence. Three shapes, and each one is a case the algorithm
 has to get right on its own:

	 two quads, disjoint         two pieces, and the vertices partition
	 two quads sharing a vertex  one piece, because sharing a vertex is the rule
	 one quad                    one piece, and it is the source itself

 The second is the one worth building deliberately. "Two squares" and "two
 squares that touch at a corner" look identical in a bounding box and in a
 triangle count, and a splitter that partitioned by *triangle adjacency along an
 edge* rather than by shared vertex would cut the second one in half.
*>
module three_tests::split;

import three;
import vk;
import std::core::test;
import std::collections::list;
import std::math;
import std::math::vector;

alias Vec3 = float[<3>];
alias Vec2 = float[<2>];

const uint W = 96;
const uint H = 72;

macro @with_pass(; @body(three::Renderer* renderer))
{
	vk::Instance instance = three::create_instance(false, headless: true)!!;
	defer instance.free();

	three::Renderer renderer;
	renderer.init(instance, (vk::SurfaceKHR)null, W, H)!!;
	defer renderer.free();

	renderer.pass.init(&renderer.gpu, &renderer.target)!!;

	@body(&renderer);
}

<*
 A quad at `x`, as four vertices and two triangles, appended to `out`.

 Carries normals, uvs and vertex colours, so that a piece's streams can be
 checked against the vertices they came from rather than only its positions.
 The uv is `(corner index / 4, x)` — distinct per vertex *and* per quad, which is
 what makes "the piece kept the right uvs" a real check rather than one every
 partition would pass.

 @param share : `A vertex index in out.positions to reuse as this quad's first corner, or -1 for four fresh ones.`
*>
fn void quad(three::GeometryBuilder* out, float x, int share = -1)
{
	uint first = (uint)out.positions.len();
	Vec3[4] corners = {
		{ x - 0.5, -0.5, 0 }, { x + 0.5, -0.5, 0 }, { x + 0.5, 0.5, 0 }, { x - 0.5, 0.5, 0 },
	};
	uint[4] index;
	foreach (i, corner : corners)
	{
		if (i == 0 && share >= 0)
		{
			index[0] = (uint)share;
			continue;
		}
		index[i] = (uint)out.positions.len();
		out.positions.push(corner);
		out.normals.push({ 0, 0, 1 });
		out.uvs.push({ (float)i / 4.0f, x });
		out.colors.push({ x, (float)i, 0, 1 });
	}
	out.triangle(index[0], index[1], index[2]);
	out.triangle(index[0], index[2], index[3]);
	// Silences the unused warning on `first` while keeping the name for a reader
	// following the index arithmetic.
	(void)first;
}

fn three::AssetId built_from(three::Renderer* renderer, String key, three::GeometryBuilder* geometry)
{
	return renderer.pass.assets.upload_built(&renderer.gpu, key, "merged", geometry)!!;
}

<*
 Two quads that share no vertex come apart into two meshes, and every vertex
 goes to exactly one of them.

 The claim in three parts, because two of them are what a partition that merely
 *looks* right would get wrong:

 - **Two pieces.** The count.
 - **Four vertices each, two triangles each.** A splitter that emitted every
   vertex into every piece would pass a count check and fail this.
 - **The positions are the two quads and not a mixture.** Piece 0's x extent is
   the left quad's and piece 1's is the right one's, so a partition that assigned
   triangles to the wrong root shows up as a box in the wrong place.

 And the streams: normals, uvs and colours are checked to be present at the piece's
 own vertex count. `quad` gives every vertex a distinct uv, so a piece that took
 the *source's* uv array wholesale would have eight of them for four positions and
 `upload_built` would have left `has_uvs` false.

 **Proved by injection**, twice, and both land on the vertex count rather than on
 the piece count — which is the argument for checking it. The per-piece vertex
 dedup removed, so a corner shared by a quad's two triangles is written twice:
 "piece 0 has 6 vertices, expected 4". And the membership test removed, so every
 triangle goes into every piece: "piece 0 has 8 vertices, expected 4" — two pieces
 that are each the whole mesh, which a count of two and a pair of bounding boxes
 would both have accepted.

 What does *not* fire is dropping `join(b, c)` from the walk, and the reason is
 worth knowing: a quad's two triangles are `(0,1,2)` and `(0,2,3)`, so `join(a, b)`
 alone already puts both of them under vertex 0's root and membership is decided
 by the first corner. A fixture that could see it would need a piece whose
 triangles are connected only through their second and third corners, which no
 quad is.
*>
fn void two_disjoint_quads_come_apart() @test
{
	@with_pass(; three::Renderer* renderer)
	{
		three::Assets* assets = &renderer.pass.assets;

		three::GeometryBuilder geometry;
		geometry.init();
		defer geometry.free();
		quad(&geometry, -2.0);
		quad(&geometry, 2.0);

		three::AssetId merged = built_from(renderer, "<merged two>", &geometry);

		List{three::MeshPiece} pieces;
		pieces.init(mem, 4);
		defer pieces.free();

		uint count = assets.split_mesh(&renderer.gpu, merged, 0, &pieces)!!;
		test::@check(count == 2, "two disjoint quads came apart into %d pieces", count);
		test::@check(pieces.len() == 2, "and %d were appended", pieces.len());

		float[2] centres;
		foreach (i, piece : pieces)
		{
			three::GpuMesh* mesh = assets.mesh(piece.asset, piece.mesh);
			test::@check(mesh != null, "piece %d has no mesh", i);
			if (mesh == null) continue;

			test::@check(mesh.vertex_count == 4, "piece %d has %d vertices, expected 4", i, mesh.vertex_count);
			test::@check(mesh.index_count == 6, "piece %d has %d indices, expected 6", i, mesh.index_count);
			test::@check(mesh.has_normals, "piece %d lost its normals", i);
			test::@check(mesh.has_uvs, "piece %d lost its uvs", i);

			centres[i] = (mesh.bounds.min.x + mesh.bounds.max.x) * 0.5f;
			float width = mesh.bounds.max.x - mesh.bounds.min.x;
			test::@check(math::abs(width - 1.0f) < 1e-4f,
				"piece %d is %f wide, so it is not one quad", i, width);
		}

		// In index order, so the left quad is first — `split_mesh` numbers the
		// pieces by where their first triangle appears.
		test::@check(math::abs(centres[0] + 2.0f) < 1e-4f,
			"the first piece is centred at %f, expected -2", centres[0]);
		test::@check(math::abs(centres[1] - 2.0f) < 1e-4f,
			"the second piece is centred at %f, expected 2", centres[1]);
	};
}

<*
 Two quads that share one corner are one piece.

 The rule is "share a vertex", not "share an edge", and this is the shape that
 tells the two apart. A merged kit is merged by concatenation and never shares a
 vertex between two buildings, so the case this rules out is a splitter that cut
 a genuinely connected surface — a terrain with the houses extruded out of it,
 which is exactly what `split.c3`'s header says must come back whole.

 It also reaches the one-component short-circuit: what comes back is *this* mesh
 rather than a copy of it, and the asset count says so. That is the correctness
 half of the short-circuit rather than the saving — the header has why re-reading
 an `upload_built` mesh through the picking tree would rebuild its uvs.

 **Proved by injection.** The short-circuit removed, so one component is uploaded
 as a copy: "the one piece is a different mesh from the source: asset 1 mesh 0".
*>
fn void two_quads_sharing_a_corner_are_one_piece() @test
{
	@with_pass(; three::Renderer* renderer)
	{
		three::Assets* assets = &renderer.pass.assets;

		three::GeometryBuilder geometry;
		geometry.init();
		defer geometry.free();
		quad(&geometry, -0.5);
		// The second quad's first corner *is* the first quad's second vertex.
		quad(&geometry, 0.5, share: 1);

		uint assets_before = assets.resident();
		three::AssetId merged = built_from(renderer, "<merged touching>", &geometry);

		List{three::MeshPiece} pieces;
		pieces.init(mem, 4);
		defer pieces.free();

		uint count = assets.split_mesh(&renderer.gpu, merged, 0, &pieces)!!;
		test::@check(count == 1, "two quads sharing a corner came apart into %d pieces", count);

		test::@check(pieces[0].asset.index == merged.index && pieces[0].mesh == 0,
			"the one piece is a different mesh from the source: asset %d mesh %d",
			pieces[0].asset.index, pieces[0].mesh);
		test::@check(assets.resident() == assets_before + 1,
			"the source was copied rather than answered with: %d assets, was %d",
			assets.resident(), assets_before + 1);
	};
}

<*
 A piece keeps the source's colour and its base colour map, and holds a reference
 to the image.

 The half a partition cannot get right by accident: `upload_built` files every
 generated shape under the primitive colour and no texture, so a piece that came
 out of it unmodified is an untextured mesh in the wrong colour — a scene that
 draws and looks wrong, which is the failure this project's headers keep naming.

 The reference matters as much as the index. `Assets.release_texture` frees the
 image when the last holder lets go, so a piece that named the texture without
 retaining it would take the source's reference count to zero the first time
 anything unloaded, and the *source* would lose its map.

 **Proved by injection.** `retain_texture` removed from the piece's inherit step:
 "the pieces did not take references: 1 holder, expected 3".
*>
fn void a_piece_inherits_the_colour_and_the_map() @test
{
	@with_pass(; three::Renderer* renderer)
	{
		three::Assets* assets = &renderer.pass.assets;

		three::GeometryBuilder geometry;
		geometry.init();
		defer geometry.free();
		quad(&geometry, -2.0);
		quad(&geometry, 2.0);

		three::AssetId merged = built_from(renderer, "<merged coloured>", &geometry);

		// `load_texture_file` hands back a slot with one reference, which stands in
		// for the source mesh's hold — assigning `source.texture` below does not
		// take one, because nothing in the engine assigns that field directly.
		int texture = assets.load_texture_file(&renderer.gpu, "test/fixtures/checker.png")!!;
		three::GpuMesh* source = assets.mesh(merged, 0);
		source.texture = texture;
		source.base_color = { 0.25, 0.5, 0.75, 1.0 };

		List{three::MeshPiece} pieces;
		pieces.init(mem, 4);
		defer pieces.free();
		assets.split_mesh(&renderer.gpu, merged, 0, &pieces)!!;

		foreach (i, piece : pieces)
		{
			three::GpuMesh* mesh = assets.mesh(piece.asset, piece.mesh);
			if (mesh == null) continue;
			test::@check(mesh.texture == texture,
				"piece %d wears texture %d rather than the source's %d", i, mesh.texture, texture);
			test::@check(math::abs(mesh.base_color[2] - 0.75f) < 1e-4f,
				"piece %d has base colour b=%f rather than the source's 0.75", i, mesh.base_color[2]);
		}

		// One for the load and one for each of the two pieces.
		test::@check(assets.texture_refs(texture) == 3,
			"the pieces did not take references: %d holders, expected 3", assets.texture_refs(texture));
	};
}

<*
 A line mesh has no triangles to cut, and says so rather than cutting its
 index pairs into threes.

 `upload_built(lines: true)` skips the picking tree, which is what
 `Assets.read_geometry` reads a generated mesh through — so the refusal falls out
 of the same test that makes a helper unpickable, and this pins that it is a
 refusal and not an empty answer.
*>
fn void a_line_mesh_cannot_be_split() @test
{
	@with_pass(; three::Renderer* renderer)
	{
		three::Assets* assets = &renderer.pass.assets;

		three::AssetId box = assets.lines(&renderer.gpu, { .kind = three::LineKind.BOX })!!;

		List{three::MeshPiece} pieces;
		pieces.init(mem, 4);
		defer pieces.free();

		fault why = @catch(assets.split_mesh(&renderer.gpu, box, 0, &pieces));
		test::@check(why == three::MESH_CANNOT_BE_SPLIT,
			"a line box was split into %d pieces", pieces.len());
	};
}
