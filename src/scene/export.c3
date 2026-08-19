<*
 Getting the scene back out: a `.glb` writer over the scene graph.

 `plan.md` §5 scopes this as "one `mesh` per unique asset and one `node` per
 instance, with materials and textures deduplicated by content hash across every
 source file", and it is the third of M6's three things — the one that makes the
 scene readable from outside rather than merely measurable from inside.

 ## The dedup is the asset system's, not a second one

 The interesting claim in the plan is the content-hash dedup, and it needed no
 hashing here at all. `GpuMesh.texture` is already an index into `Assets.textures`,
 which is deduplicated by a hash of the *decoded* image across every loaded
 file — so two kit packs that share an atlas already point at one slot, and
 keying the exported image on that index is that dedup, reused. A second hash
 over the encoded bytes would have been a second answer to a question that was
 already settled, and the two could disagree.

 Geometry is deduplicated the same way, on `(asset, mesh)`, which is the pair the
 renderer buckets on. A thousand walls placed from one kit are a thousand nodes
 over one mesh in the file exactly as they are one draw call in the frame.

 ## Where the vertices come from, and why not from the GPU

 Nothing is read back off the device. Three sources, in this order:

 1. **A mesh out of a file** is re-read from the file, which is still open —
    `Assets.load` parses the JSON and keeps the stream, so the accessors are
    right there. This is exact: the normals and uvs written out are the bytes
    that were read in.
 2. **A generated shape** is tessellated again from the `Primitive` the asset
    kept. Thirty-two bytes per asset, against the twenty per vertex that keeping
    the streams would have cost every scene whether or not it ever exported.
 3. **A convex hull** is rebuilt from `hull_positions`/`hull_triangles`, the CPU
    copy the picking tree already holds. Its normals are per face and its
    vertices are split per face, so recomputing them from the triangles gives
    back exactly what `build_convex` produced. It has no uvs and never did.

 ## What is deliberately not in the file

 **The export is what the frame shows.** Helpers and hidden subtrees are not in
 it — a `.glb` with the debug boxes baked in is a file nobody wants, and a node
 whose subtree is switched off is not part of the picture being exported. One
 rule, two consequences.

 **A `ShaderMaterial` is not exported, and cannot be.** It is a Slang pipeline;
 glTF describes surfaces, not programs. A mesh drawn under one exports with the
 base colour and texture its geometry carries, which is what a consumer will
 render it with. Nothing is silently dropped that a script cannot see: the report
 names the count.

 **Per-copy colour becomes material colour**, which is the one place the export
 cannot keep the draw-call count. `mesh.color` is per instance and free here
 because it rides in the instance record; glTF has no per-instance channel at
 all, so a copy with its own colour needs its own material and therefore its own
 `mesh` entry. The *geometry* is still shared — the accessors are written once
 and referenced by each — so a thousand colours cost a thousand tiny mesh
 entries and one set of vertices, rather than a thousand copies of the vertices.
 A scene that leaves `color` alone round-trips its draw calls exactly.
*>
module three;

import std::io;
import std::io::file;
import std::math;
import std::math::vector;
import std::collections::list;
import gltf;
import collision;

faultdef EXPORT_HAS_NOTHING_TO_WRITE, EXPORT_PATH_IS_EMPTY;

<*
 What one export wrote.

 Reported rather than merely done, for `UnloadReport`'s reason: an agent that
 cannot see the numbers has no way to tell a working export from one that wrote
 an empty scene, and "it produced a file" is not the same claim as "it produced
 the scene".
*>
struct ExportReport
{
	// Distinct `(asset, mesh)` pairs whose vertices were written. The number that
	// should match `stats().uniqueMeshes` for a scene using no per-copy colour.
	uint meshes;
	// `mesh` entries in the document, which is one per `(geometry, material)`
	// pair — the same as `meshes` until two copies of one shape disagree about
	// their colour. See the header.
	uint entries;
	uint materials;
	uint images;
	// Every node written, groups included.
	uint nodes;
	// Of those, the ones that draw.
	uint instances;
	// Nodes left out because they were helpers or were switched off.
	uint skipped;
	// Nodes drawn under a ShaderMaterial, which was not written. They are in the
	// file with their glTF material; this is how many lost a custom shader.
	uint shaded;
	usz bytes;
}

// Where a mesh's vertices ended up in the document, so a second node naming the
// same `(asset, mesh)` references them rather than writing them again.
struct ExportGeometry @local
{
	AssetId asset;
	uint mesh;
	int positions;
	int normals;
	int uvs;
	int indices;
}

// A material by content: the colour it resolves to and the image it samples.
// Two nodes agreeing on both share one, which is what "deduplicated by content"
// means once the image itself is already deduplicated.
struct ExportMaterial @local
{
	float[4] base_color;
	// The document's texture index, or -1. Named for what it identifies rather
	// than for the array it indexes, because the image and the texture are
	// one-to-one here — see `ExportImage`.
	int image;
	uint material;
}

// One `(geometry, material)` pair, and the `mesh` entry that is that pair.
struct ExportEntry @local
{
	uint geometry;
	int material;
	uint entry;
}

// The device texture slot an exported image came from. `GpuMesh.texture` is
// already content-deduplicated across every loaded file, so this key *is* the
// content hash — see the header.
struct ExportImage @local
{
	int device;
	// The document's *texture* index rather than its image index, because that is
	// what a material references. glTF splits the two so that one image can be
	// sampled two ways; nothing here samples anything two ways, so the image and
	// the texture are one-to-one and one memo covers both.
	uint texture;
}

// Everything one export is part-way through, so the walk can be a plain
// recursive function rather than a closure over nine locals.
struct Exporter @local
{
	MeshPass* pass;
	gltf::GltfBuilder* out;
	List{ExportGeometry} geometry;
	List{ExportMaterial} materials;
	List{ExportEntry} entries;
	List{ExportImage} images;
	ExportReport report;
}

<*
 Write the scene to a `.glb`.

 @param path : `Where to write. The extension is not inspected; the bytes are always a binary glTF.`
 @return? EXPORT_PATH_IS_EMPTY : `No path was given.`
 @return? EXPORT_HAS_NOTHING_TO_WRITE : `Nothing in the scene draws — an empty scene, or one holding only helpers and hidden subtrees.`
*>
fn ExportReport? MeshPass.export_scene(&self, String path)
{
	if (path.len == 0) return EXPORT_PATH_IS_EMPTY~;

	gltf::GltfBuilder builder = gltf::builder(mem);
	defer builder.free();
	builder.generator = "three.c3";

	Exporter state = { .pass = self, .out = &builder };
	state.geometry.init(mem, 16);
	state.materials.init(mem, 8);
	state.entries.init(mem, 16);
	state.images.init(mem, 8);
	defer
	{
		state.geometry.free();
		state.materials.free();
		state.entries.free();
		state.images.free();
	}

	// The root goes in as a node of its own rather than having its children
	// hoisted, because a Scene is an Object3D here — moving it moves everything,
	// and hoisting would drop that transform on the floor.
	int root = state.walk(self.scene.root)!;
	if (root < 0) return EXPORT_HAS_NOTHING_TO_WRITE~;
	builder.add_root((uint)root);

	if (state.report.instances == 0) return EXPORT_HAS_NOTHING_TO_WRITE~;

	builder.save_glb(path)!;
	// The file's size rather than the blob's, so the number reported is the one a
	// script sees on disk — the JSON chunk and the header are most of a small
	// export and none of a large one.
	state.report.bytes = (usz)file::get_size(path)!;
	return state.report;
}

<*
 One node and its subtree, depth first.

 @return `The document's node index, or -1 for a subtree that contributed nothing and should not be linked.`
*>
fn int? Exporter.walk(&self, NodeId id)
{
	Node* node = self.pass.scene.node(id);
	if (node == null) return -1;

	// The two exclusions, and both are the same rule: the file is what the frame
	// shows. A helper is drawn over the scene rather than in it, and a subtree
	// that is switched off is not being looked at.
	if (node.material == LINE_MATERIAL || !node.visible)
	{
		self.report.skipped++;
		return -1;
	}

	int entry = -1;
	if (node.asset.is_set() && self.pass.assets.mesh(node.asset, node.mesh) != null)
	{
		entry = self.mesh_entry(node)!;
	}

	// A node's own children may all have dropped out; it is still written when it
	// draws, and dropped when it does not, so an exported document has no groups
	// standing over nothing.
	// Heap-backed rather than `tmem`: this recurses, and a temp allocation per
	// level of a deep hierarchy is not freed until the enclosing pool exits —
	// which for a caller that opened none is never.
	List{uint} children;
	children.init(mem, node.children.len() > 0 ? node.children.len() : 1);
	defer children.free();
	foreach (child : node.children)
	{
		int built = self.walk(child)!;
		if (built >= 0) children.push((uint)built);
	}

	if (entry < 0 && children.len() == 0)
	{
		// Not counted as skipped: nothing was left out, there was nothing there.
		return -1;
	}

	uint written = self.out.add_node(
		node.name, entry, -1,
		node.position, node.rotation, node.scale,
	);
	foreach (child : children) self.out.add_child(written, child);

	self.report.nodes++;
	if (entry >= 0)
	{
		self.report.instances++;
		if (node.material != DEFAULT_MATERIAL) self.report.shaded++;
	}
	return (int)written;
}

<*
 The `mesh` entry this node draws: its geometry, and the material its colour and
 texture resolve to.

 @return `The document's mesh index, or -1 for a mesh whose vertices cannot be written.`
*>
fn int? Exporter.mesh_entry(&self, Node* node)
{
	GpuMesh* mesh = self.pass.assets.mesh(node.asset, node.mesh);

	int geometry = self.geometry_for(node.asset, node.mesh)!;
	if (geometry < 0) return -1;

	// `mesh.color` multiplies albedo in the shader, and glTF's baseColorFactor
	// multiplies the base colour texture the same way — so the product is exactly
	// what the pixel was.
	float[4] color = {
		mesh.base_color[0] * node.color[0],
		mesh.base_color[1] * node.color[1],
		mesh.base_color[2] * node.color[2],
		mesh.base_color[3] * node.color[3],
	};
	int texture = self.texture_for(node.asset, node.mesh)!;
	int material = self.material_for(color, texture);

	foreach (&known : self.entries)
	{
		if (known.geometry == (uint)geometry && known.material == material) return (int)known.entry;
	}

	uint written = self.out.add_mesh(mesh.name);
	ExportGeometry* streams = &self.geometry[(usz)geometry];

	gltf::WriteAttribute[3] attributes;
	usz count = 0;
	attributes[count++] = { .name = "POSITION", .accessor = (uint)streams.positions };
	if (streams.normals >= 0) attributes[count++] = { .name = "NORMAL", .accessor = (uint)streams.normals };
	if (streams.uvs >= 0) attributes[count++] = { .name = "TEXCOORD_0", .accessor = (uint)streams.uvs };

	self.out.add_primitive(written, attributes[:count], streams.indices, material);
	self.entries.push({ .geometry = (uint)geometry, .material = material, .entry = written });
	self.report.entries++;
	return (int)written;
}

<*
 The accessors for one `(asset, mesh)`, written once however many nodes draw it.

 @return `A slot in the exporter's own geometry list, or -1 for a mesh with no vertices to write — a line helper's, whose indices are pairs.`
*>
fn int? Exporter.geometry_for(&self, AssetId asset, uint mesh)
{
	foreach (i, &known : self.geometry)
	{
		if (known.asset == asset && known.mesh == mesh) return (int)i;
	}

	GeometryBuilder streams;
	streams.init();
	defer streams.free();

	if (!self.pass.assets.read_geometry(asset, mesh, &streams)) return -1;
	if (streams.positions.len() == 0 || streams.indices.len() < 3) return -1;

	ExportGeometry written = {
		.asset = asset,
		.mesh = mesh,
		.positions = (int)self.out.add_positions(streams.positions.array_view()),
		.normals = -1,
		.uvs = -1,
		.indices = (int)self.out.add_indices(streams.indices.array_view()),
	};
	// Short is absent, which is the same test `upload_primitive` applies: a
	// normals array that does not cover every vertex is one a consumer would read
	// past the end of.
	if (streams.normals.len() == streams.positions.len())
	{
		written.normals = (int)self.out.add_vec3(streams.normals.array_view());
	}
	if (streams.uvs.len() == streams.positions.len())
	{
		written.uvs = (int)self.out.add_vec2(streams.uvs.array_view());
	}

	self.geometry.push(written);
	self.report.meshes++;
	return (int)self.geometry.len() - 1;
}

<*
 The exported texture this mesh samples, or -1.

 Keyed on `GpuMesh.texture`, the device slot — which is deduplicated by a hash of
 the decoded image across every loaded file, so two kit packs sharing an atlas
 write it once. The *bytes* come from whichever file is asked first, and they are
 the file's own encoded bytes rather than anything re-encoded here.

 **The image is written without a name.** A glTF image name is decorative, and
 the source file's is not readable this late: `gltf::Image.name` is a slice into
 the JSON document, which does not outlive the load — the same borrow that makes
 `Assets.load` copy every mesh name the moment it has one. Reading it here
 produced nine bytes of fill pattern inside a JSON string and a file nothing
 could parse, which is a good argument for not carrying decoration across a
 lifetime boundary.
*>
fn int? Exporter.texture_for(&self, AssetId id, uint mesh)
{
	GpuMesh* gpu_mesh = self.pass.assets.mesh(id, mesh);
	if (gpu_mesh.texture < 0) return -1;

	foreach (&known : self.images)
	{
		if (known.device == gpu_mesh.texture) return (int)known.texture;
	}

	Asset* asset = self.pass.assets.slot(id);
	if (asset == null || !asset.has_stream || gpu_mesh.gltf_mesh < 0) return -1;

	int source = source_image_index(asset, gpu_mesh);
	if (source < 0) return -1;

	char[]? encoded = asset.stream.get_image_data((uint)source);
	if (catch encoded) return -1;

	gltf::ImageType mime = asset.stream.gltf.images[source].mimeType;
	uint image = self.out.add_image("", encoded, mime);
	// No sampler: a texture that names none takes the viewer's default, which is
	// repeat with mipmapped linear filtering — what `Assets` uploads with.
	uint texture = self.out.add_texture(image);
	self.images.push({ .device = gpu_mesh.texture, .texture = texture });
	self.report.images++;
	return (int)texture;
}

<*
 Which of the source file's images a mesh's base colour texture came from.

 Walked from the primitive rather than remembered, because `GpuMesh.texture` is
 an index into the *shared* table and deliberately says nothing about which file
 or which image it was — that is what makes it the dedup key.
*>
fn int source_image_index(Asset* asset, GpuMesh* mesh) @local
{
	if (mesh.gltf_mesh >= asset.stream.gltf.meshes.len()) return -1;
	gltf::Mesh source = asset.stream.gltf.meshes[mesh.gltf_mesh];
	if (mesh.gltf_primitive < 0 || mesh.gltf_primitive >= source.primitives.len()) return -1;

	sz? material_index = source.primitives[mesh.gltf_primitive].attributes.get("material");
	if (catch material_index) return -1;
	if (material_index >= asset.stream.gltf.materials.len()) return -1;

	int texture = asset.stream.gltf.materials[material_index].baseColorTexture.source;
	if (texture < 0 || texture >= asset.stream.gltf.textures.len()) return -1;

	int image = asset.stream.gltf.textures[texture].source;
	return image >= 0 && image < asset.stream.gltf.images.len() ? image : -1;
}

<*
 The material for a colour and a texture, written once per distinct pair.
*>
fn int Exporter.material_for(&self, float[4] color, int texture)
{
	foreach (&known : self.materials)
	{
		if (known.image != texture) continue;
		if (known.base_color[0] != color[0] || known.base_color[1] != color[1]) continue;
		if (known.base_color[2] != color[2] || known.base_color[3] != color[3]) continue;
		return (int)known.material;
	}

	// Fully rough and not metallic: `mesh.slang` is a Lambert term and a texture,
	// with no specular of any kind, so a metallic material would render in a glTF
	// viewer as something this never showed.
	uint written = self.out.add_material(
		"",
		{ color[0], color[1], color[2], color[3] },
		metallic: 0.0,
		roughness: 1.0,
		base_color_texture: texture,
	);
	self.materials.push({ .base_color = color, .image = texture, .material = written });
	self.report.materials++;
	return (int)written;
}

<*
 One mesh's vertices, from wherever they can be had without touching the device.

 The three sources are the header's, in its order. Nothing here uploads, decodes
 or reads back.

 @return `False when there is nothing writable — a line mesh, whose indices are pairs rather than triangles.`
*>
fn bool Assets.read_geometry(&self, AssetId id, uint mesh, GeometryBuilder* out)
{
	Asset* asset = self.slot(id);
	if (asset == null) return false;
	GpuMesh* gpu_mesh = self.mesh(id, mesh);
	if (gpu_mesh == null) return false;

	if (asset.has_stream && gpu_mesh.gltf_mesh >= 0)
	{
		return read_stream_geometry(asset, gpu_mesh, out);
	}

	if (asset.has_primitive)
	{
		asset.primitive.build(out);
		return out.positions.len() > 0;
	}

	// A hull, and anything else built through `upload_built` that kept a picking
	// tree. Not a line mesh: `upload_built` skips the tree for those, which is
	// exactly why the arrays being empty is the test.
	if (gpu_mesh.hull_positions.len == 0 || gpu_mesh.hull_triangles.len == 0) return false;
	return read_hull_geometry(gpu_mesh, out);
}

<*
 Re-read a primitive out of the file it was loaded from.

 The `@each_*` macros rather than a memcpy for `upload_primitive`'s reason: a
 glTF buffer view may be strided, and these are what know the stride. What comes
 out is tightly packed, which is what the writer's accessors want.
*>
fn bool read_stream_geometry(Asset* asset, GpuMesh* mesh, GeometryBuilder* out) @local
{
	if (mesh.gltf_mesh >= asset.stream.gltf.meshes.len()) return false;
	gltf::Mesh source = asset.stream.gltf.meshes[mesh.gltf_mesh];
	if (mesh.gltf_primitive < 0 || mesh.gltf_primitive >= source.primitives.len()) return false;

	gltf::Primitive primitive = source.primitives[mesh.gltf_primitive];
	asset.stream.@each_position(primitive; Vec3 position, sz i) { out.positions.push(position); };
	if (out.positions.len() == 0) return false;

	asset.stream.@each_normal(primitive; Vec3 normal, sz i) { out.normals.push(normal); };
	asset.stream.@each_texcoord(primitive, 0; Vec2 uv, sz i) { out.uvs.push(uv); };

	read_indices(&asset.stream, primitive, &out.indices);
	// A primitive with no index accessor is a plain vertex list, and glTF lets a
	// primitive be written the same way — but the writer's dedup and the reader's
	// bucket both key on an index accessor being there, so it is filled in for the
	// reason `upload_primitive` fills it in.
	if (out.indices.len() == 0)
	{
		for (uint i = 0; i < out.positions.len(); i++) out.indices.push(i);
	}
	return true;
}

<*
 A hull, out of the CPU copy the picking tree holds.

 Its normals are recomputed rather than stored, and that is exact rather than
 approximate: `build_convex` splits a vertex per face, so every vertex here
 belongs to exactly one triangle and the accumulated normal is that triangle's.
 A hull has no uvs and never had any — its faces meet at creases and there is no
 unwrap of an arbitrary hull that does not seam.
*>
fn bool read_hull_geometry(GpuMesh* mesh, GeometryBuilder* out) @local
{
	foreach (position : mesh.hull_positions) out.positions.push(position);
	foreach (i, position : mesh.hull_positions) out.normals.push({ 0, 0, 0 });

	foreach (triangle : mesh.hull_triangles)
	{
		uint a = triangle[0];
		uint b = triangle[1];
		uint c = triangle[2];
		if (a >= out.positions.len() || b >= out.positions.len() || c >= out.positions.len()) continue;

		Vec3 face = (mesh.hull_positions[b] - mesh.hull_positions[a])
			.cross(mesh.hull_positions[c] - mesh.hull_positions[a]);
		out.normals[a] = out.normals[a] + face;
		out.normals[b] = out.normals[b] + face;
		out.normals[c] = out.normals[c] + face;

		out.indices.push(a);
		out.indices.push(b);
		out.indices.push(c);
	}

	foreach (i, normal : out.normals)
	{
		float length = math::sqrt(normal.x * normal.x + normal.y * normal.y + normal.z * normal.z);
		// A vertex no triangle reached keeps a zero normal rather than a NaN one.
		// glTF requires unit normals, and zero is the lesser of the two lies.
		out.normals[i] = length > 0 ? normal / length : (Vec3){ 0, 0, 0 };
	}
	return out.indices.len() >= 3;
}
