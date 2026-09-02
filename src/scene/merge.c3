<*
 There is no merge, only split — until now. `split.c3` reads a kit's geometry
 back off the host and uploads one asset per connected piece; this is that
 path in reverse. A ten-building kit where every building is a hierarchy of
 boxes is 2,463 nodes and 2,463 draw calls' worth of bookkeeping even though
 most of them share one material — merging bakes a subtree of meshes into one
 asset, so a piece drawn as forty boxes becomes the mesh it always looked like.

 ## Concatenation, and nothing cleverer

 A merge is `split.c3`'s union-find run backwards without the find: every
 source mesh's vertices are transformed by its own matrix and appended.
 Coincident interior faces — the inside of a wall behind a window frame, the
 underside of a roof panel sitting in the attic — are still there afterwards,
 only now inside one mesh instead of scattered across forty. `ExtrudeGeometry`
 is the tool that removes them; this only removes the *nodes*, which is a
 different saving (draw calls and instance bookkeeping) from `ExtrudeGeometry`'s
 (overdraw and triangle count), and a script wants both for the same wall.

 ## The frame

 `prelude.js` walks the subtree and hands over one 4x4 per mesh: the product of
 the local matrices from the mesh up to, but excluding, whatever frame the
 caller asked for — see `merge` there. This side only ever multiplies a vertex
 by the matrix it was given; it has no opinion about where that matrix came
 from, which is what lets the same host code serve both spellings
 (`three.merge(root)` and `three.merge([mesh, ...])`).

 Positions transform by the matrix. Normals transform by its inverse transpose,
 renormalised — `node.c3`'s `normal_matrix`, already written for the reason
 explained there: the upper 3x3 alone is only correct under uniform scale, and
 a kit scales things. A negative determinant is a mirror, and a mirrored
 triangle's winding is flipped along with it so every face still points the
 way its normal says.

 ## What is retained, and why

 `Assets.read_geometry`'s fallback for an asset with no glTF stream, no
 `Primitive` and no `Heightfield` is `read_hull_geometry`: it *rebuilds*
 normals by averaging the triangles at each vertex and *projects* uvs from
 whatever normal came out of that average. That is the right answer for a
 hull, which never had real uvs to begin with, and the wrong one for a merge,
 which is concatenated from meshes that mostly did. So a merged asset keeps its
 `GeometryBuilder` on the slot — positions, normals, uvs, colours, indices,
 already baked — the way a `Heightfield` sits beside a `TerrainGeometry`'s
 asset, and `Assets.read_geometry` copies it out exactly instead of falling
 through. That is what makes `scene.export` write a merged mesh's real uvs
 rather than a projection, and what makes `MeshRef.split()` on a merged mesh
 hand back pieces with their normals intact.

 ## Colour: baked, not refused

 `shaders/mesh.slang` multiplies three factors into albedo — the material's own
 `base_color`, the copy's `mesh.color` (srgb-decoded), and a `COLOR_0` vertex
 attribute when the mesh has one (`draw.flags & FLAG_HAS_COLORS`, linear,
 untouched) — so a vertex-colour channel is already how this renderer lets one
 mesh vary across its own surface. A merge only has one instance and therefore
 one `mesh.color` afterwards, so a wall merged with a differently tinted door
 would lose the door's tint if `color` were simply dropped. Instead each
 input's `color` — decoded the same way the shader decodes `mesh.color`,
 `srgb_to_linear_rgb` — is folded into that piece's share of the merged
 `COLOR_0` stream, multiplied against whatever vertex colour the source mesh
 already carried. A merge whose inputs are all the untinted default carries no
 colour stream at all, exactly as an ordinary untextured mesh does.

 `variant` has no vertex-level equivalent — it selects a row of a material's
 own table — so a script asking to merge meshes that disagree about it is
 refused in `prelude.js` rather than silently drawn with one of the two rows.

 ## The dedup key

 `merge_key` hashes what actually varies the output: each input's asset index,
 asset generation, mesh index, 16 matrix floats and 4 colour floats, the way
 `convex_key` hashes a point cloud's bits rather than rounding them. Bit-exact
 and generation-aware on purpose — the same subtree merged twice in the same
 run is one asset, and a kit reloaded under a new generation is honestly a
 different input even if nothing about the file changed. Colour is in the key,
 unlike `MeshRef.split()`'s inherited colour and `Assets.primitive`'s key,
 because here it is not a paint decision layered over shared geometry — it is
 baked into the vertex stream the key identifies, so two merges of one subtree
 differing only in `color` produce different vertices and must answer with
 different assets, not the first tint silently drawn under the second's name.
*>
module three;

import std::collections::list;
import std::math;
import std::math::vector;
import std::math::matrix;

faultdef NOTHING_TO_MERGE, MESH_CANNOT_BE_MERGED, TOO_MANY_MERGE_MESHES;

<*
 Beyond this many meshes a merge is a mistake rather than a kit: a subtree this
 wide is almost certainly a scatter of a thousand identical instances, which
 wants to stay instanced — merging them would trade one small upload and one
 instanced draw for one very large upload and still one draw, for no reason.

 `prelude.js` refuses past this with a sentence naming the count; this is the
 backstop for a forged `__three.merge` call, as `MAX_CONVEX_POINTS` is for
 `convex`.
*>
const uint MAX_MERGE_MESHES = 4096;

<*
 One mesh going into a merge: which asset and mesh, the matrix that carries its
 vertices into the merge's frame, and the per-copy colour to fold into them.

 `color` is what `mesh.color` reads back as — straight from JavaScript, not yet
 srgb-decoded, the same units `GpuMesh.base_color` and `PRIMITIVE_COLOR` are
 written in.
*>
struct MergeInput
{
	AssetId asset;
	uint mesh;
	Matrix4f matrix;
	float[4] color;
}

<*
 Whether `color` is white — the identity for both the srgb decode and the
 multiply — within the precision a JavaScript double survives being written as
 a float and read back.
*>
fn bool color_is_white(float[4] color) @local
{
	for (usz channel = 0; channel < 4; channel++)
	{
		if (math::abs(color[channel] - 1.0f) > 1e-6f) return false;
	}
	return true;
}

<*
 The determinant of `m`'s upper-left 3x3 — the linear part, translation left
 out — whose sign is all a winding flip needs. `normal_matrix` computes the
 same 3x3 on the way to inverting it; this is the other thing the codebase
 already had a use for that 3x3 for, `scene/node.c3`'s determinant a script
 never sees.
*>
fn float linear_determinant(Matrix4f m) @local
{
	Matrix3f linear = {
		.m = {
			m.m[0], m.m[1], m.m[2],
			m.m[4], m.m[5], m.m[6],
			m.m[8], m.m[9], m.m[10],
		}
	};
	return linear.determinant();
}

<*
 The identity of a merge: equal keys mean the same meshes, at the same
 matrices and colours, out of the same asset generations.

 FNV-1a, 64-bit, over each input's asset index, asset generation, mesh index,
 sixteen matrix floats and four colour floats in turn — `convex_key`'s scheme,
 because the arithmetic problem is the same one: a key spelled out in decimal
 would be kilobytes for a hundred-mesh subtree, and a hash of the bits is exact
 where rounding would merge two subtrees that do not actually match. Colour is
 hashed rather than left out because it is baked into the vertex stream this
 key identifies — two merges of one subtree differing only in `color` are two
 different sets of vertices and have to be two different assets.
*>
fn String merge_key(MergeInput[] inputs, Allocator allocator) @local
{
	ulong hash = 0xcbf29ce484222325;
	foreach (input : inputs)
	{
		uint[3] ids = { input.asset.index, input.asset.generation, input.mesh };
		for (usz slot = 0; slot < 3; slot++)
		{
			uint id = ids[slot];
			for (usz byte = 0; byte < 4; byte++)
			{
				hash ^= (ulong)((id >> (uint)(byte * 8)) & 0xff);
				hash *= 0x100000001b3;
			}
		}
		for (usz k = 0; k < 16; k++)
		{
			uint bits = bitcast(input.matrix.m[k], uint);
			for (usz byte = 0; byte < 4; byte++)
			{
				hash ^= (ulong)((bits >> (uint)(byte * 8)) & 0xff);
				hash *= 0x100000001b3;
			}
		}
		for (usz k = 0; k < 4; k++)
		{
			uint bits = bitcast(input.color[k], uint);
			for (usz byte = 0; byte < 4; byte++)
			{
				hash ^= (ulong)((bits >> (uint)(byte * 8)) & 0xff);
				hash *= 0x100000001b3;
			}
		}
	}
	return string::format(allocator, "<merge n=%d h=%x>", inputs.len, hash);
}

<*
 Concatenates every input mesh into one asset, each one's vertices baked
 through its own matrix, and uploads it — or answers with the asset already
 built for exactly this set of inputs.

 Mirrors `Assets.split_mesh`'s shape: `ensure_uploaded`, `read_geometry` into a
 scratch `GeometryBuilder` per source, then `upload_built` once over the
 concatenation. Unlike a split, nothing here partitions anything — every
 triangle every input contributes lands in the one output, coincident interior
 faces included. See the header for the frame, the colour and what is
 retained.

 @param inputs : `One entry per mesh, in the order they end up in the merged index buffer.`
 @param [out] failed_at : `Set to the index into inputs that a MESH_CANNOT_BE_MERGED or MESH_HAS_LAYERS fault is about, so the caller can name it. Untouched on success or on a whole-array fault.`
 @return `The asset's handle, for Scene.add_mesh.`
 @return ? NOTHING_TO_MERGE : `inputs is empty. prelude.js refuses this first; this is the backstop for a forged call.`
 @return ? TOO_MANY_MERGE_MESHES : `More than MAX_MERGE_MESHES inputs.`
 @return ? MESH_CANNOT_BE_MERGED : `inputs[*failed_at] names an unknown asset or mesh index, or one with no triangles to read — a line mesh, or a mesh whose geometry could not be read back at all.`
 @return ? MESH_HAS_LAYERS : `inputs[*failed_at] carries a CUSTOM_materials_layers stack, which a merged mesh cannot inherit — the same refusal Assets.split_mesh makes and for the same reason.`
*>
fn AssetId? Assets.merge(&self, Gpu* gpu, MergeInput[] inputs, uint* failed_at)
{
	if (!self.started) self.init();
	if (inputs.len == 0) return NOTHING_TO_MERGE~;
	if (inputs.len > MAX_MERGE_MESHES) return TOO_MANY_MERGE_MESHES~;

	@pool()
	{
		String key = merge_key(inputs, tmem);
		if (try hit = self.built(key)) return hit;

		// Whether the merged mesh needs a COLOR_0 stream at all — see the
		// header. Decided across every input up front, rather than per input
		// as they are read, so a plain wall read before a tinted door does not
		// leave the door's tint with nowhere to land: `GeometryBuilder`'s
		// streams are optional by *length*, and a colour written for input 4
		// alone would leave `geometry.colors` shorter than `geometry.positions`
		// and silently drop the whole attribute, tint included.
		bool needs_colors = false;
		foreach (input : inputs)
		{
			if (!color_is_white(input.color)) { needs_colors = true; break; }
		}

		GeometryBuilder geometry;
		geometry.init();
		defer geometry.free();

		foreach (i, input : inputs)
		{
			self.ensure_uploaded(input.asset, input.mesh);
			GpuMesh* source = self.mesh(input.asset, input.mesh);
			if (source == null) { *failed_at = (uint)i; return MESH_CANNOT_BE_MERGED~; }
			if (source.layers.present) { *failed_at = (uint)i; return MESH_HAS_LAYERS~; }

			GeometryBuilder piece;
			piece.init();
			defer piece.free();
			if (!self.read_geometry(input.asset, input.mesh, &piece))
			{
				*failed_at = (uint)i;
				return MESH_CANNOT_BE_MERGED~;
			}

			usz vertices  = (usz)piece.positions.len();
			usz triangles = (usz)piece.indices.len() / 3;
			if (vertices == 0 || triangles == 0)
			{
				*failed_at = (uint)i;
				return MESH_CANNOT_BE_MERGED~;
			}

			bool piece_has_normals = (usz)piece.normals.len() == vertices;
			bool piece_has_uvs     = (usz)piece.uvs.len() == vertices;
			bool piece_has_colors  = (usz)piece.colors.len() == vertices;
			if (piece_has_colors) needs_colors = true;

			Matrix4f nmat = normal_matrix(input.matrix);
			bool flip     = linear_determinant(input.matrix) < 0;
			float[4] tint = srgb_to_linear_rgb(input.color);

			uint base = (uint)geometry.positions.len();
			for (usz v = 0; v < vertices; v++)
			{
				geometry.positions.push(transform_point(input.matrix, piece.positions[(sz)v]));
				if (piece_has_normals)
				{
					Vec3 n    = transform_direction(nmat, piece.normals[(sz)v]);
					float len = n.length();
					geometry.normals.push(len > 1e-8f ? n / len : (Vec3) { 0, 0, 0 });
				}
				if (piece_has_uvs) geometry.uvs.push(piece.uvs[(sz)v]);
				if (needs_colors)
				{
					Vec4 c = piece_has_colors ? piece.colors[(sz)v] : (Vec4) { 1, 1, 1, 1 };
					geometry.colors.push({
						c[0] * tint[0],
						c[1] * tint[1],
						c[2] * tint[2],
						c[3] * tint[3],
					});
				}
			}

			for (usz t = 0; t < triangles; t++)
			{
				uint a = base + piece.indices[(sz)(t * 3)];
				uint b = base + piece.indices[(sz)(t * 3 + 1)];
				uint c = base + piece.indices[(sz)(t * 3 + 2)];
				// A mirrored input flips the triangle's winding along with its
				// normal, so the two keep agreeing under CULL_MODE_BACK_BIT —
				// the same swap `build_convex` makes when a face comes out
				// wound the wrong way.
				if (flip) { geometry.triangle(a, c, b); } else { geometry.triangle(a, b, c); }
			}
		}

		if (geometry.indices.len() < 3) return MESH_CANNOT_BE_MERGED~;

		AssetId built = self.upload_built(gpu, key, "merge", &geometry)!;

		// Retained exactly, beside the asset the upload just claimed — copied
		// rather than moved out of `geometry`, so the `defer` above still gives
		// the local copy back and `Assets.read_geometry`'s `has_merged` branch
		// has its own to hand out on every future read.
		Asset* slot = self.slot(built);
		slot.merged.init();
		slot.merged.positions.add_all(&geometry.positions);
		slot.merged.normals.add_all(&geometry.normals);
		slot.merged.uvs.add_all(&geometry.uvs);
		slot.merged.colors.add_all(&geometry.colors);
		slot.merged.indices.add_all(&geometry.indices);
		slot.has_merged = true;

		return built;
	};
}
