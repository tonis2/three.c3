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
 One `.glb` or `.gltf`, described.

 `path` is root-relative and is exactly what `three.load` wants, so an agent
 that read an inventory can load from it without joining anything.
*>
struct InventoryEntry
{
	String path; // owned, root-relative
	List{InventoryMesh} meshes;
	List{String} animations; // owned strings
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