<*
 Cutting one merged mesh into the pieces it is actually made of.

 Every AI-generated kit ships as one merged mesh. A town square arrives as a
 single primitive with 23 buildings in it, and there is nothing a scene can do
 with that: one mesh is one transform, so the buildings cannot be moved, placed,
 rotated, culled or picked apart.

 ## Connected components

 Two triangles belong to the same piece when they share a vertex, and the pieces
 are the equivalence classes of that relation. That is right for this input
 because a merged kit is merged by *concatenation* — the buildings were separate
 meshes a tool appended into one buffer, so nothing welded their vertices and the
 seams the merge erased are exactly the ones this finds.

 What it cannot cut is a genuinely connected surface: a terrain with the houses
 extruded out of it, a character welded to its base. Those come back as one
 piece, which is honest — there is no seam, and inventing one would put a cut
 through the middle of a wall.

 Union-find over the vertex indices, with path halving and union by size. Almost
 linear in the triangle count; the arrays are two `uint`s per vertex and are
 freed before anything is uploaded.

 ## What a piece inherits

 The source's base colour and base colour map, taking a reference to the image
 the way any other mesh naming one does. Normals, uvs and vertex colours come
 across per vertex, because the split is a partition of the vertex list rather
 than a re-tessellation — a piece's vertices are the source's, renumbered.

 It does *not* get a `CUSTOM_materials_layers` stack, and a mesh that has one is
 refused rather than split into pieces that quietly lost it. A stack is a
 material property resolved against the file's own images, and half-carrying it
 would produce a picture that looks plausible and is wrong.

 ## The pieces are ordinary assets

 One `upload_built` per piece, filed under a key derived from the source's, so a
 second split of the same mesh answers with the same assets. Afterwards they are
 indistinguishable from a hull or a box: pickable, instanced, exportable,
 unloadable one at a time.

 A mesh that turns out to be one component answers with the source itself — same
 asset, same mesh index, nothing uploaded. That is a correctness short-circuit,
 not just a saving: `Assets.read_geometry` reaches a mesh built through
 `upload_built` by its picking tree, which carries positions and triangles and
 *recomputes* normals and uvs the way a hull wants them, so copying a piece back
 through that would replace its uv stream with a projection.

 This is a load-time tool. It reads geometry back through `Assets.read_geometry`
 — the exporter's host-side path, touching no device — so it is a walk over
 vertices and an upload per piece, whenever the script asks. Nothing calls it
 automatically, because a kit that is already cut would pay for it every run.
*>
module three;

import std::collections::list;
import std::math;
import collision;

faultdef MESH_CANNOT_BE_SPLIT, MESH_HAS_LAYERS, TOO_MANY_SPLIT_PIECES;

<*
 One piece: which asset it landed in and which mesh of it.

 The mesh index is carried because a piece is not always mesh 0 — a mesh that was
 already one component answers with the source's own handle, and that mesh may be
 any of the file's.
*>
struct MeshPiece
{
	AssetId asset;
	uint mesh;
}

<*
 How many pieces one mesh may be cut into.

 A bound on a mistake rather than a budget. A kit is tens of pieces and the town
 square was 23; a number in the thousands means the input is a point cloud, a
 particle dump or a mesh whose triangles genuinely do not touch, and uploading
 one asset per triangle would be a stall and then a scene nothing can draw.

 Refused with the count, so the caller learns what it handed over.
*>
const uint MAX_SPLIT_PIECES = 512;

<*
 Union-find over the vertex indices, with path halving and union by size.

 Kept as a struct so the two arrays have one owner and one `free`.
 `parent[i] == i` is a root; `size` is only meaningful at a root.
*>
struct VertexUnion @local
{
	uint[] parent;
	uint[] size;
}

fn void VertexUnion.init(&self, usz count)
{
	self.parent = mem::new_array(uint, (sz)count);
	self.size = mem::new_array(uint, (sz)count);
	for (usz i = 0; i < count; i++)
	{
		self.parent[i] = (uint)i;
		self.size[i] = 1;
	}
}

fn void VertexUnion.free(&self)
{
	if (self.parent.len > 0) mem::free(self.parent);
	if (self.size.len > 0) mem::free(self.size);
	*self = { };
}

<*
 The root of `at`, flattening the path on the way.

 Path *halving* rather than full compression: one pass, no recursion, no second
 walk, and the same near-constant amortised cost. Iterative because the recursive
 version's depth is the tree's, and a pathological merge order over a million
 vertices would be a stack overflow rather than a slow answer.
*>
fn uint VertexUnion.find(&self, uint at)
{
	uint node = at;
	while (self.parent[node] != node)
	{
		self.parent[node] = self.parent[self.parent[node]];
		node = self.parent[node];
	}
	return node;
}

fn void VertexUnion.join(&self, uint a, uint b)
{
	uint ra = self.find(a);
	uint rb = self.find(b);
	if (ra == rb) return;
	// By size, so the tree stays shallow independently of the order the
	// triangles arrive in.
	if (self.size[ra] < self.size[rb])
	{
		uint swap = ra;
		ra = rb;
		rb = swap;
	}
	self.parent[rb] = ra;
	self.size[ra] += self.size[rb];
}

<*
 Cuts one mesh into its connected components and uploads each as its own asset.

 The pieces come back in the order their first triangle appears in the source's
 index buffer, which is stable for a given file and makes the keys stable too. A
 mesh that is one connected surface comes back as one piece rather than a fault:
 "this was already one thing" is an answer, not an error.

 Nothing about the source changes. It stays loaded, stays uploaded and keeps its
 references, so a script that splits a kit and then unloads the kit gets what it
 asked for — the pieces hold their own image references.

 @param id : `The asset the mesh belongs to.`
 @param mesh : `Which of its meshes to cut.`
 @param [out] pieces : `One MeshPiece per component, appended. Not cleared first.`
 @return `How many pieces the mesh turned out to be.`
 @return ? MESH_CANNOT_BE_SPLIT : `No triangles to walk — an unknown handle, a mesh index out of range, or a line mesh, whose indices are pairs.`
 @return ? MESH_HAS_LAYERS : `The mesh carries a CUSTOM_materials_layers stack, which a piece cannot inherit. See the header.`
 @return ? TOO_MANY_SPLIT_PIECES : `More components than MAX_SPLIT_PIECES.`
*>
fn uint? Assets.split_mesh(&self, Gpu* gpu, AssetId id, uint mesh, List{MeshPiece}* pieces)
{
	// The geometry has to be readable, and for a lazily-loaded glTF mesh that
	// means uploaded: `read_geometry`'s stream path needs `gltf_mesh` filled in.
	self.ensure_uploaded(id, mesh);

	GpuMesh* source = self.mesh(id, mesh);
	if (source == null) return MESH_CANNOT_BE_SPLIT~;
	if (source.layers.present) return MESH_HAS_LAYERS~;

	Asset* owner = self.slot(id);
	if (owner == null) return MESH_CANNOT_BE_SPLIT~;
	// Copied before anything can grow `self.assets` and move the slot under us.
	String source_path = owner.path;
	String source_name = source.name;
	Vec4 base_color    = source.base_color;
	int texture        = source.texture;

	@pool()
	{
		GeometryBuilder geometry;
		geometry.init();
		defer geometry.free();
		if (!self.read_geometry(id, mesh, &geometry)) return MESH_CANNOT_BE_SPLIT~;

		usz vertices  = (usz)geometry.positions.len();
		usz triangles = (usz)geometry.indices.len() / 3;
		if (vertices == 0 || triangles == 0) return MESH_CANNOT_BE_SPLIT~;

		VertexUnion sets;
		sets.init(vertices);
		defer sets.free();

		for (usz t = 0; t < triangles; t++)
		{
			uint a = geometry.indices[(sz)(t * 3)];
			uint b = geometry.indices[(sz)(t * 3 + 1)];
			uint c = geometry.indices[(sz)(t * 3 + 2)];
			// An index past the end of the vertex list is a file this cannot
			// trust to describe anything, and a `find` on it would read out of
			// bounds. Skipped rather than refused: `upload_primitive` already
			// uploaded the same indices, so the mesh draws — and a triangle
			// nothing can place belongs to no piece.
			if (a >= vertices || b >= vertices || c >= vertices) continue;
			sets.join(a, b);
			sets.join(b, c);
		}

		// Roots in the order their first triangle appears, so the pieces are
		// numbered the way somebody reading the file would number them.
		// `piece_of` is indexed by root and holds one past the piece index, so
		// zero is "not a root anything reached".
		uint[] piece_of = mem::new_array(uint, (sz)vertices);
		defer mem::free(piece_of);
		List{usz} first_triangle;
		first_triangle.tinit(8);

		for (usz t = 0; t < triangles; t++)
		{
			uint a = geometry.indices[(sz)(t * 3)];
			if (a >= vertices) continue;
			uint root = sets.find(a);
			if (piece_of[root] != 0) continue;
			if (first_triangle.len() >= MAX_SPLIT_PIECES) return TOO_MANY_SPLIT_PIECES~;
			first_triangle.push(t);
			piece_of[root] = (uint)first_triangle.len();
		}

		uint count = (uint)first_triangle.len();
		if (count == 0) return MESH_CANNOT_BE_SPLIT~;

		// Already one thing. See the header — this is a correctness
		// short-circuit, not only a saving.
		if (count == 1)
		{
			pieces.push({ .asset = id, .mesh = mesh });
			return 1;
		}

		// One builder, refilled per piece. `clear` keeps the capacity, so the
		// second and later pieces of a big kit allocate nothing.
		GeometryBuilder piece;
		piece.init();
		defer piece.free();

		// Where each source vertex landed in the piece being built, plus the
		// piece it was written for — so one array serves every piece instead of
		// being cleared N times over a million entries.
		uint[] moved_to = mem::new_array(uint, (sz)vertices);
		defer mem::free(moved_to);
		uint[] moved_in = mem::new_array(uint, (sz)vertices);
		defer mem::free(moved_in);

		bool has_normals = (usz)geometry.normals.len() == vertices;
		bool has_uvs     = (usz)geometry.uvs.len() == vertices;
		bool has_colors  = (usz)geometry.colors.len() == vertices;

		for (uint p = 0; p < count; p++)
		{
			piece.positions.clear();
			piece.normals.clear();
			piece.uvs.clear();
			piece.colors.clear();
			piece.indices.clear();

			for (usz t = 0; t < triangles; t++)
			{
				uint a = geometry.indices[(sz)(t * 3)];
				if (a >= vertices) continue;
				if (piece_of[sets.find(a)] != p + 1) continue;

				for (usz corner = 0; corner < 3; corner++)
				{
					uint vertex = geometry.indices[(sz)(t * 3 + corner)];
					// `p + 1` for the same reason `piece_of` is offset: zero is
					// the value the array was allocated with, and piece 0 is real.
					if (moved_in[vertex] != p + 1)
					{
						moved_in[vertex] = p + 1;
						moved_to[vertex] = (uint)piece.positions.len();
						piece.positions.push(geometry.positions[(sz)vertex]);
						if (has_normals) piece.normals.push(geometry.normals[(sz)vertex]);
						if (has_uvs) piece.uvs.push(geometry.uvs[(sz)vertex]);
						if (has_colors) piece.colors.push(geometry.colors[(sz)vertex]);
					}
					piece.indices.push(moved_to[vertex]);
				}
			}

			// The source's path and mesh index, so a second split of the same
			// mesh is a lookup rather than a second upload.
			String key    = string::tformat("<split %s#%d/%d of %d>", source_path, mesh, p, count);
			String label  = string::tformat("%s piece %d", source_name, p);
			AssetId built = self.upload_built(gpu, key, label, &piece)!;

			// The colour and the map, after the upload rather than through it: a
			// piece already built under this key is somebody else's mesh holding
			// somebody else's reference, and writing over it would take a
			// reference twice.
			GpuMesh* fresh = self.mesh(built, 0);
			if (fresh != null && fresh.texture < 0)
			{
				fresh.base_color = base_color;
				if (texture >= 0)
				{
					self.retain_texture(texture);
					fresh.texture = texture;
				}
			}
			pieces.push({ .asset = built, .mesh = 0 });
		}

		return count;
	};
}