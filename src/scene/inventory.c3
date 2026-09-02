<*
 What is in a game's directory, without uploading any of it.

 An `--assets` boot scans for `.glb` and `.gltf` and describes each one — mesh
 names, animation names, skin count, triangle count, bounds — for the price of
 the JSON chunk. No buffer is read, no image is decoded, nothing reaches the
 device.

 That makes "what have I got" a cheap question. Without it the only way to find
 out what a file contains is to load it, which means uploading forty files just
 to read their mesh names. It is also what a game's `main.js` wants at boot: a
 manifest nobody had to write by hand or can forget to update.

 The numbers are exact rather than estimated because `gltf::open` parses the
 JSON and stops, and everything here is read out of that: an accessor's `count`
 is in the JSON, so a triangle count is a sum; a position accessor's `min`/`max`
 are required by the spec, which is what makes bounds free. A `.glb`'s binary
 chunk is never seeked to — on a 200 MB kit that is the difference between a
 boot and a wait.
*>
module three;

import std::io::path;
import std::collections::list;
import std::math;
import std::math::vector;
import std::math::matrix;
import gltf;
import collision;

faultdef ASSETS_ROOT_IS_NOT_A_DIRECTORY;

<*
 One mesh, as the file describes it.
*>
struct InventoryMesh
{
	String name; // owned
	uint triangles;
}

<*
 One connection point, as the file describes it.

 A marker is a leaf node with no mesh — the empty a kit author drops where two
 pieces are meant to meet, the same way a Blender kit ships them. `position` is
 composed through the TRS of every node between `piece` and the marker, but not
 `piece`'s own transform — the frame `asset.node(piece)` hands a script, since
 that is the piece a marker's position is useful relative to.
*>
struct InventoryMarker
{
	String name;  // owned
	String piece; // owned; empty when the marker is itself a top-level node
	Vec3 position;
}

<*
 One `.glb` or `.gltf`, described.

 `path` is root-relative and is exactly what `three.load` wants, so an agent
 that read an inventory can load from it without joining anything.
*>
struct InventoryEntry
{
	String path; // owned, root-relative
	List{InventoryMesh} meshes;
	List{String} animations; // owned strings
	List{InventoryMarker} markers;
	uint skins;
	uint nodes;
	uint triangles;
	collision::Aabb3 bounds;
	bool has_bounds;
}

fn void InventoryEntry.free(&self)
{
	if (self.path.len > 0) self.path.free(mem);
	foreach (&entry : self.meshes)
	{
		if (entry.name.len > 0) entry.name.free(mem);
	}
	self.meshes.free();
	foreach (name : self.animations)
	{
		if (name.len > 0) name.free(mem);
	}
	self.animations.free();
	// Always freed, unlike the guards above: `push_marker` always copies both
	// strings, even the empty `piece` a top-level marker gets, and `.copy(mem)`
	// on an empty string still allocates — skip it on `.len == 0` and it leaks.
	foreach (&marker : self.markers)
	{
		marker.name.free(mem);
		marker.piece.free(mem);
	}
	self.markers.free();
	*self = { };
}

alias Inventory = List{InventoryEntry};

fn void Inventory.free_entries(&self)
{
	foreach (&entry : *self) entry.free();
	self.free();
}

<*
 Describes every glTF under `root`, recursively.

 Sorted by path, so two runs on the same directory answer identically — a
 filesystem's own order is not a promise, and a reshuffling inventory makes
 every diff of a generated manifest unreadable.

 A file that will not parse is skipped rather than fatal: one corrupt asset in a
 kit of forty should cost that one asset.

 @param root : `The assets directory.`
 @return `Owned by the caller; free it with Inventory.free_entries.`
 @return ? ASSETS_ROOT_IS_NOT_A_DIRECTORY : `Nothing there, or not a directory.`
*>
fn Inventory? take_inventory(String root)
{
	if (!path::is_dir((Path)root)) return ASSETS_ROOT_IS_NOT_A_DIRECTORY~;

	Inventory found;
	found.init(mem, 8);

	@pool()
	{
		PathList? listed = path::ls(tmem, (Path)root, no_dirs: true, recursive: true);
		if (catch listed) return found;

		// `ls` answers in the filesystem's order, which is nobody's contract.
		String[] names = alloc::new_array(tmem, String, (sz)listed.len());
		usz count      = 0;
		foreach (entry : listed)
		{
			String name = (String)entry;
			if (!is_gltf_path(name)) continue;
			names[count++] = name;
		}
		sort_paths(names[:count]);

		foreach (name : names[:count])
		{
			if (try entry = describe_gltf(root, name)) found.push(entry);
		}
	};
	return found;
}

<*
 Whether a name ends in a glTF extension, case-insensitively.

 Case-folded because a kit exported on Windows routinely arrives with `.GLB`,
 and a file skipped for its capitalisation is a file an agent is told does not
 exist.
*>
fn bool is_gltf_path(String name) @local
{
	return ends_with_fold(name, ".glb") || ends_with_fold(name, ".gltf");
}

fn bool ends_with_fold(String text, String suffix) @local
{
	if (text.len < suffix.len) return false;
	usz start = text.len - suffix.len;
	for (usz i = 0; i < suffix.len; i++)
	{
		char a = text[start + i];
		char b = suffix[i];
		if (a >= 'A' && a <= 'Z') a += 32;
		if (a != b) return false;
	}
	return true;
}

<*
 Byte order, shortest-first on a tie. C3 will not order `String` with `<` —
 ordering text is a locale question — but a path is not text in that sense, and
 byte order is exactly what a stable listing wants.
*>
fn bool before(String a, String b) @local
{
	usz shared = a.len < b.len ? a.len : b.len;
	for (usz i = 0; i < shared; i++)
	{
		if (a[i] != b[i]) return a[i] < b[i];
	}
	return a.len < b.len;
}

<*
 Insertion sort: an inventory is tens of files, not thousands, and a sort with
 no allocation is one less thing that can fail inside a boot.
*>
fn void sort_paths(String[] names) @local
{
	for (usz i = 1; i < names.len; i++)
	{
		String held = names[i];
		usz j       = i;
		while (j > 0 && before(held, names[j - 1]))
		{
			names[j] = names[j - 1];
			j--;
		}
		names[j] = held;
	}
}

<*
 Reads one file's JSON and answers with what it says about itself.

 The stream is closed on every path including the failing ones, which is why the
 `defer` is early rather than a close at the end.
*>
fn InventoryEntry? describe_gltf(String root, String relative) @local
{
	@pool()
	{
		String full             = string::tformat("%s/%s", root, relative);
		gltf::GltfStream stream = gltf::open(full, tmem)!;
		defer stream.close();

		InventoryEntry entry = { .path = relative.copy(mem) };
		entry.meshes.init(mem, stream.gltf.meshes.len());
		entry.animations.init(mem, stream.gltf.animations.len());
		entry.markers.init(mem, 4);
		entry.nodes = (uint)stream.gltf.nodes.len();
		entry.skins = (uint)stream.gltf.skins.len();

		foreach (&mesh : stream.gltf.meshes)
		{
			uint triangles = 0;
			foreach (primitive : mesh.primitives)
			{
				triangles += primitive_triangles(&stream.gltf, primitive);
				widen(&entry, &stream.gltf, primitive);
			}
			entry.triangles += triangles;
			entry.meshes.push({ .name = mesh.name.copy(mem), .triangles = triangles });
		}

		foreach (&animation : stream.gltf.animations)
		{
			entry.animations.push(animation.name.copy(mem));
		}

		find_markers(&entry, &stream.gltf);

		return entry;
	};
}

<*
 A primitive's triangle count, from accessor counts alone.

 Indexed geometry counts its indices, unindexed counts its positions — the same
 rule `read_indices` follows when it actually uploads one, reached here by
 reading the JSON instead of the buffer.
*>
fn uint primitive_triangles(gltf::Gltf* doc, gltf::Primitive primitive) @local
{
	if (try indices = primitive.attributes.get("indices"))
	{
		return doc.accessors[indices].count / 3;
	}
	if (try positions = primitive.attributes.get("POSITION"))
	{
		return doc.accessors[positions].count / 3;
	}
	return 0;
}

<*
 Grows the entry's bounds by a primitive's position accessor.

 The spec requires `min` and `max` on a POSITION accessor, which is the only
 reason bounds are free here: they sit in the JSON beside the count.
*>
fn void widen(InventoryEntry* entry, gltf::Gltf* doc, gltf::Primitive primitive) @local
{
	sz? positions = primitive.attributes.get("POSITION");
	if (catch positions) return;

	gltf::Accessor accessor = doc.accessors[positions];
	Vec3 low                = { accessor.min[0], accessor.min[1], accessor.min[2] };
	Vec3 high               = { accessor.max[0], accessor.max[1], accessor.max[2] };

	if (!entry.has_bounds)
	{
		entry.bounds = { .min = low, .max = high };
		entry.has_bounds = true;
		return;
	}
	entry.bounds.min = math::min(entry.bounds.min, low);
	entry.bounds.max = math::max(entry.bounds.max, high);
}

<*
 Whether a node is a marker: a leaf with no mesh and nothing else already
 claiming it. The piece root itself is usually an empty too, but it has
 children, so it never matches this — and `scene.export()` writes a `camera`
 node and a `sun` node beside every kit, both leaves with no mesh, which are
 not connection points either. A node already spoken for by one of those
 roles is excluded on the same grounds a mesh is.
*>
fn bool is_marker(gltf::Node* node) @local
{
	return node.mesh == -1 && node.camera == -1 && node.light == -1
		&& node.skin == -1 && node.collider == -1 && node.motion == -1 && node.joint == -1
		&& node.children.len() == 0;
}

<*
 Fills `entry.markers`, one entry per leaf node with no mesh.

 A top-level node — nothing else in the file lists it as a child — is a piece
 in its own right; `gltf` already resolves that into `Node.parent` while
 parsing, so this reads it rather than re-deriving it from a scene's own node
 list. A top-level node that is itself a marker (no mesh, no children) reports
 with an empty `piece`, since it is not sitting under one.
*>
fn void find_markers(InventoryEntry* entry, gltf::Gltf* doc) @local
{
	foreach (uint i, node : doc.nodes)
	{
		gltf::Node* top = doc.nodes.get_ref(i);
		if (top.parent != null) continue;
		if (is_marker(top))
		{
			push_marker(entry, top, "", marker_matrix(top, null));
			continue;
		}
		foreach (child : top.children)
		{
			collect_markers(entry, doc, doc.nodes.get_ref(child), top);
		}
	}
}

<*
 Walks one piece's subtree for markers, `piece` staying the same top-level
 node however deep the recursion goes.
*>
fn void collect_markers(InventoryEntry* entry, gltf::Gltf* doc, gltf::Node* node, gltf::Node* piece) @local
{
	if (is_marker(node))
	{
		push_marker(entry, node, piece.name, marker_matrix(node, piece));
		return;
	}
	foreach (child : node.children)
	{
		collect_markers(entry, doc, doc.nodes.get_ref(child), piece);
	}
}

<*
 `node`'s local matrix, composed with every ancestor's up to but not including
 `piece` (or all the way to the file's root, for `piece == null`) — the frame
 `asset.node(piece)` hands a script, which is why the piece's own transform is
 left out.
*>
fn Matrix4f marker_matrix(gltf::Node* node, gltf::Node* piece) @local
{
	Matrix4f composed = node.local_matrix();
	gltf::Node* up = node;
	while (up.parent != null && up.parent != piece)
	{
		composed = up.parent.local_matrix().mul(composed);
		up = up.parent;
	}
	return composed;
}

fn void push_marker(InventoryEntry* entry, gltf::Node* node, String piece, Matrix4f local) @local
{
	entry.markers.push({
		.name = node.name.copy(mem),
		.piece = piece.copy(mem),
		.position = { local.m[12], local.m[13], local.m[14] },
	});
}