<*
 Getting the scene back out: a `.glb` writer over the scene graph.

 One `mesh` per unique asset and one `node` per instance, with materials and
 textures deduplicated by content hash across every source file.

 ## The dedup is the asset system's, not a second one

 The content-hash dedup needs no hashing here at all. `GpuMesh.texture` is
 already an index into `Assets.textures`, which is deduplicated by a hash of the
 *decoded* image across every loaded file — so two kit packs that share an atlas
 already point at one slot, and keying the exported image on that index is that
 dedup, reused. A second hash over the encoded bytes would be a second answer to
 a question already settled, and the two could disagree.

 Geometry is deduplicated the same way, on `(asset, mesh)`, which is the pair the
 renderer buckets on. A thousand walls placed from one kit are a thousand nodes
 over one mesh in the file exactly as they are one draw call in the frame.

 ## Where the vertices come from, and why not from the GPU

 Nothing is read back off the device. Three sources, in this order:

 1. A mesh out of a file is re-read from the file, which is still open —
    `Assets.load` parses the JSON and keeps the stream, so the accessors are
    right there. This is exact: the normals and uvs written out are the bytes
    that were read in.
 2. A generated shape is tessellated again from the `Primitive` the asset kept.
    Thirty-two bytes per asset, against the twenty per vertex that keeping the
    streams would cost every scene whether or not it ever exported.
 3. A convex hull is rebuilt from `hull_positions`/`hull_triangles`, the CPU copy
    the picking tree already holds. Its normals are per face and its vertices are
    split per face, so recomputing them from the triangles gives back exactly
    what `build_convex` produced — including its uvs, which are a per-face planar
    projection and so are recomputed from the face rather than stored.

 ## What is deliberately not in the file

 The export is what the frame shows. Helpers and hidden subtrees are not in it —
 a `.glb` with the debug boxes baked in is a file nobody wants, and a node whose
 subtree is switched off is not part of the picture being exported.

 A `ShaderMaterial` is not exported, and cannot be: it is a Slang pipeline, and
 glTF describes surfaces rather than programs. A mesh drawn under one exports
 with the base colour and texture its geometry carries. Nothing is silently
 dropped that a script cannot see — the report names the count.

 Lines are not in it yet. A line mesh has no CPU copy of its vertices
 (`upload_built` skips `build_bvh`, and `build_bvh` is what keeps the copy) and a
 script's `three.lines()` is indistinguishable from a helper, since both draw
 with `LINE_MATERIAL`. Both are fixable and neither is fixed; the format has
 `mode: LINES` waiting.

 ## The scene around the meshes

 A file holding the right geometry still opens wrong if it opens pointing
 somewhere else, unlit. So the camera and the light go in too, as one glTF camera
 and one `KHR_lights_punctual` directional light, each on a node of its own.

 The materials carry `doubleSided` from `material.side`, `KHR_texture_transform`
 from `material.repeat` and `material.offset` — a tiling floor is the most
 ordinary thing a script builds, and its texture would otherwise arrive stretched
 once across the whole surface — and the normal, occlusion and emissive maps of
 the source material.

 Not the metallic-roughness half: there is no specular term here, so those
 describe an equation nothing evaluates, and a number in the file that never
 affected a pixel is worse than its absence.

 ## Material layers, recovered from the file rather than the frame

 `CUSTOM_materials_layers` is the exception to "the export is what the frame
 shows", and it has to be. A layer stack reaches the frame as a *generated*
 `ShaderMaterial`, so under that rule it would be lost like any other program and
 a terrain would come back as a flat quad in its base colour.

 It is written from the source document instead: `Assets.load` keeps the stream
 open, so the material's parsed `layers_ext` is still there, complete and in the
 file's own arrangement. That is lossless where the renderer's own copy is not —
 `GpuLayers` drops the PBR half and the height data, rearranges the masks through
 `hoist_shared_mask`, and exists only after an upload this path never performs.

 A `LayeredMaterial` a script built goes back too, by the other door.
 `js/prelude/layers.js` sends the description across at construction beside the
 shader it generates (`Material.script_layers`), because a shader cannot be read
 back: "this layer multiplies" is a choice of expression by the time the Slang
 exists. That path is lossless for its own reason — a script stack has no PBR
 half and no height data to lose, because the JS API refuses both by name. Its
 images have no file behind them, so they are read off the device and encoded.

 The script's stack wins when a node has both, and either kind leaves the
 material counted in `shaded`, because it is still a program glTF cannot hold.
 `layers` is what says the stack itself survived.

 One consequence for the vertices: a layer may take its mask from a vertex colour
 rather than an image, so `COLOR_0` is written whenever the source mesh carried
 one. Without it such a layer would come back naming an attribute the file does
 not have — a mask reading zero, which is a layer that silently vanishes.

 ## Per-copy colour, and the instanced nodes that carry it

 `mesh.color` is per instance and free in the frame — it rides in the `Instance`
 record and is read by `SV_InstanceID`, so a thousand colours are one draw call.
 Core glTF has no per-instance channel at all: a material belongs to a primitive,
 a primitive to a mesh, and a node points at a mesh. Written that way a thousand
 colours are a thousand materials, a thousand `mesh` entries and — on reload — a
 thousand draw calls.

 `EXT_mesh_gpu_instancing` is the channel. One node carries an array of
 transforms and draws its mesh once per entry, and the extension's `attributes`
 dictionary takes application-specific names beside `TRANSLATION`/`ROTATION`/
 `SCALE`, underscore-prefixed by convention. `_COLOR_0` is that: a fourth
 accessor, read by the same instance index, holding what `mesh.color` was.

 A reader that does not know `_COLOR_0` skips the key and gets the transforms and
 the material's own colour — a scene in one colour rather than a scene in the
 wrong place. That is why the tint is not folded into the material here: the
 untinted material *is* the fallback.

 ## What gets collapsed, and what keeps its name

 Sibling nodes drawing the same `(asset, mesh, material)` — the frame's own
 bucket key — are written as one instanced node, but only when there are two or
 more of them. A batch of one is one draw call whichever way it is written, so a
 lone node keeps its name, its place in the tree and its own tinted material.
 What collapses is the mass-produced copy, whose name is `crate.012`.

 The material is in that key and the tint is not, and the two look alike from a
 distance. A tint is `mesh.color`, one `Vec4` per copy, riding in the instance
 array. A material is a blend mode, a cull mode, a UV transform, a map and a
 layer stack, none of which the extension has a channel for and none of which can
 be averaged — so copies that disagree about it are different buckets in the
 frame and different nodes here.

 A node with children of its own is never collapsed: instancing replicates a
 node's mesh, not its subtree. Groups are therefore untouched, and what flattens
 is a run of leaves under one parent, into one node beneath that same parent.

 Instance transforms are relative to the node that carries them, so the instanced
 node sits at identity under the shared parent and each copy's own local TRS goes
 in unchanged. Nothing is baked into world space.

 ## `flatten`, and the case the sibling rule cannot reach

 Copies placed with `asset.instantiate()` are not siblings. Each arrives wrapped
 in a group of its own — that is what an instantiated subtree *is* — so a hundred
 crates from one kit are a hundred groups holding one crate each, and no two
 share a parent.

 Untinted that costs nothing: geometry is deduplicated on `(asset, mesh)` across
 the whole scene regardless of parentage. What it costs is the *tint*, the one
 thing that has to travel per copy: six colours become six materials, six `mesh`
 entries and six buckets.

 `flatten` is the way out, and a parameter rather than the default because it
 trades something real. It abandons the hierarchy: every drawing node is taken in
 *world space*, batched by shape and material wherever it sits, and written as a
 handful of instanced nodes under one root. The groups go, and so do the names of
 the copies inside them. What comes back is the same picture in the same number
 of draw calls, and no longer a scene anybody can navigate in a viewer.

 So: leave it off for a file a person will open, turn it on for a file that is a
 payload.
*>
module three;

import std::io;
import std::io::file;
import std::math;
import std::math::vector;
import std::collections::list;
import gltf;
import image;
import image::png;
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
	// `mesh` entries in the document, which is one per `(geometry, material)` pair
	// — the same as `meshes` until two copies of one shape disagree about their
	// colour. See the header.
	uint entries;
	uint materials;
	uint images;
	// Every node written, groups and instanced nodes included. Not one per copy: a
	// batch of a thousand is one entry here and a thousand in `instances`.
	uint nodes;
	// Every copy that draws, counted whether it got a node of its own or a slot in
	// an instanced node's arrays. The number to compare against `stats().instances`.
	uint instances;
	// How many of `nodes` are instanced nodes. Zero for a scene with no two
	// siblings sharing a shape *and* a material, which is how a script tells
	// "instancing did not apply here" from "instancing is not working".
	uint batches;
	// Nodes left out because they were helpers or were switched off.
	uint skipped;
	// Nodes drawn under a ShaderMaterial, which was not written. They are in the
	// file with their glTF material; this is how many lost a custom shader.
	uint shaded;
	// `CUSTOM_materials_layers` records written, summed over every material that
	// carried a stack. Zero for a scene whose materials are all plain, which is how
	// a script tells "this file had no layers" from "the layers were lost" — the
	// distinction `shaded` alone cannot make, since a layered material reaches the
	// frame as a generated `ShaderMaterial` and is counted there too.
	uint layers;
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
	// COLOR_0, or -1. Only a mesh re-read out of a file can have one.
	int colors;
	int indices;
}

<*
 Everything about a node that decides which glTF material it needs.

 The whole of it is the dedup key, which is why it is one struct rather than
 eight arguments to `material_for`. Every field here is something two nodes can
 disagree about while agreeing on all the others, and each one left out of the
 key would collapse two materials into one and give both whichever was walked
 first. `transparent` is the oldest example — an opaque wall that comes back
 see-through, or glass that comes back solid, depending on walk order — and
 `double_sided`, `uv_transform` and the two stack identities fail the same way.

 The identities are indices rather than resolved contents deliberately: two nodes
 naming one material of one asset have the same maps and the same layers by
 construction, so comparing them field by field would be a deep compare to answer
 a question two integers already answer.
*>
struct ExportSurface @local
{
	float[4] base_color;
	// The document's texture index, or -1. Named for what it identifies rather
	// than for the array it indexes, because the image and the texture are
	// one-to-one here — see `ExportImage`.
	int texture;
	// `material.repeat` and `material.offset`, as `Material.uv_transform` holds
	// them: xy is the repeat, zw the offset. `UV_IDENTITY` for a material that
	// never set one, which writes no `KHR_texture_transform` at all.
	float[4] uv_transform;
	bool transparent;
	// `material.side` — `DoubleSide` is the only one glTF has a word for, and the
	// two single-sided values differ in which face they keep, which glTF cannot say
	// at all. `FrontSide` and `BackSide` therefore both write `false`.
	bool double_sided;
	// The three core maps, already resolved to this document's texture indices
	// rather than named by where they came from.
	//
	// That is the difference between a key that dedups and one that does not. Two
	// source materials of two different files can name two different images whose
	// bytes are identical; `ExportImage` collapses those to one exported texture,
	// and a key holding the source material's *index* would then keep two glTF
	// materials that are byte-for-byte the same.
	gltf::WriteTextureRef normal;
	gltf::WriteTextureRef occlusion;
	gltf::WriteTextureRef emissive;
	float[3] emissive_factor;
	// The `CUSTOM_materials_layers` stack, named by where it was read from: the
	// asset, and the index of the material inside that asset's own document.
	// `NO_ASSET`/-1 for a material with no layers.
	//
	// An identity rather than a resolved value, because a stack is a list of
	// eighteen-field records and two nodes naming one material of one asset have
	// the same layers by construction.
	AssetId layers_asset;
	int layers_material;
	// The `MeshPass.materials` index of the `three.LayeredMaterial` this draws
	// with, or -1. Its stack and its base normal map win over the source
	// document's — `script_material_index` argues why.
	int script_material;
}

fn bool ExportSurface.equals(self, ExportSurface other)
{
	if (self.texture != other.texture) return false;
	if (self.transparent != other.transparent || self.double_sided != other.double_sided) return false;
	if (!self.normal.same_as(other.normal)) return false;
	if (!self.occlusion.same_as(other.occlusion)) return false;
	if (!self.emissive.same_as(other.emissive)) return false;
	if (self.layers_material != other.layers_material) return false;
	if (self.script_material != other.script_material) return false;
	if (self.layers_material >= 0 && !(self.layers_asset == other.layers_asset)) return false;
	for (usz i = 0; i < 3; i++)
	{
		if (self.emissive_factor[i] != other.emissive_factor[i]) return false;
	}
	for (usz i = 0; i < 4; i++)
	{
		if (self.base_color[i] != other.base_color[i]) return false;
		if (self.uv_transform[i] != other.uv_transform[i]) return false;
	}
	return true;
}

// One written material, and the surface it was written for.
struct ExportMaterial @local
{
	ExportSurface key;
	uint material;
}

<*
 A run of sibling nodes drawing one shape with one material, to be written as a
 single instanced node.

 Keyed on `(asset, mesh, material)`, which is `Scene.Bucket`'s key. That is the
 point: a batch is the file's word for what the frame calls a bucket, so a run
 that is one draw call in the frame is one instanced node in the document and one
 bucket again when the file is read back.

 Keying on `(asset, mesh)` alone — on the argument that the material follows from
 the mesh — is wrong the moment a node can name a material of its own:
 `surface_for` reads the *node's* material for its opacity, blend mode, cull
 mode, UV transform, layer stack and map, and every one of those is a thing two
 siblings can disagree about while drawing one mesh. The batch would be written
 with `members[0]`'s material and the rest would inherit it: a wall and a window
 cut from one pane mesh export as two copies of whichever was added first —
 right in the count, right in the instance total, and wrong in the viewer.

 A run that splits here is not a run that lost anything: two materials over one
 mesh are two buckets in the frame already, and writing them as two instanced
 nodes sharing one set of geometry accessors is the same two draw calls back.
*>
struct ExportBatch @local
{
	AssetId asset;
	uint mesh;
	// `Node.material` — the `MeshPass.materials` index, not the document's. A
	// resolved surface would dedup two identical materials into one batch and this
	// does not, which is a split that costs a node and never a wrong colour.
	// `surface_for` is a `.glb` read and an image encode deep; running it during
	// batching to save a node is the wrong trade.
	uint material;
	List{NodeId} members;
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
	// what a material references. glTF splits the two so one image can be sampled
	// two ways; nothing here samples anything two ways, so the image and the
	// texture are one-to-one and one memo covers both.
	uint texture;
}

<*
 An image a material *layer* named, keyed on where it sits in the source document
 rather than on a device slot.

 A second key beside `ExportImage.device`, and it has to be. A layer's images are
 read straight out of the file the layer was read out of, so on this path there
 is no device slot to key on: a layer that was never uploaded has none, and one
 that was has a slot the exporter cannot walk back to an image index.

 The consequence is that an image named both as a mesh's base colour map and as a
 layer's mask is written into the file twice. That is the answer the renderer
 gives too — `Assets` uploads it twice, once as `SRGB` and once as `LINEAR`,
 because a picture and a weight are not the same image even when they are the
 same bytes.
*>
struct ExportLayerImage @local
{
	AssetId asset;
	int image;
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
	List{ExportLayerImage} layer_images;
	ExportReport report;
}

<*
 Writes the scene to a `.glb`.

 @param path : `Where to write. The extension is not inspected; the bytes are always a binary glTF.`
 @param flatten : `Collapse every copy of a shape into one instanced node in world space, giving up the hierarchy and the copies' names to do it. See the header.`
 @return? EXPORT_PATH_IS_EMPTY : `No path was given.`
 @return? EXPORT_HAS_NOTHING_TO_WRITE : `Nothing in the scene draws — an empty scene, or one holding only helpers and hidden subtrees.`
*>
fn ExportReport? MeshPass.export_scene(&self, String path, bool flatten = false)
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
	state.layer_images.init(mem, 8);
	defer
	{
		state.geometry.free();
		state.materials.free();
		state.entries.free();
		state.images.free();
		state.layer_images.free();
	}

	// The root goes in as a node of its own rather than having its children
	// hoisted, because a Scene is an Object3D here — moving it moves everything,
	// and hoisting would drop that transform on the floor. Flattened, that
	// transform is already inside every world matrix, so the root written there is
	// at identity instead.
	int root = flatten ? state.flatten_scene()! : state.walk(self.scene.root)!;
	if (root < 0) return EXPORT_HAS_NOTHING_TO_WRITE~;
	builder.add_root((uint)root);

	if (state.report.instances == 0) return EXPORT_HAS_NOTHING_TO_WRITE~;

	// After the scene and only when there was one to write: a file with nothing in
	// it should be refused above rather than come back holding a camera and a light
	// pointed at nothing.
	state.write_camera();
	state.write_light();

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
	// shows. A helper is drawn over the scene rather than in it, and a subtree that
	// is switched off is not being looked at.
	if (node.material == LINE_MATERIAL || !node.visible)
	{
		self.report.skipped++;
		return -1;
	}

	int entry = -1;
	if (node.asset.is_set() && self.pass.assets.mesh(node.asset, node.mesh) != null)
	{
		// Tinted: this node is written as itself, so its colour has nowhere to go
		// but its material. A copy that ends up in a batch takes the other path.
		entry = self.mesh_entry(node, node.color)!;
	}

	// A node's own children may all have dropped out; it is still written when it
	// draws, and dropped when it does not, so an exported document has no groups
	// standing over nothing.
	//
	// Heap-backed rather than `tmem`: this recurses, and a temp allocation per
	// level of a deep hierarchy is not freed until the enclosing pool exits —
	// which for a caller that opened none is never.
	List{uint} children;
	children.init(mem, node.children.len() > 0 ? node.children.len() : 1);
	defer children.free();
	self.place_children(node, &children)!;

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
		if (self.loses_its_shader(node.material)) self.report.shaded++;
	}
	return (int)written;
}

<*
 Writes a node's children into `into`, as instanced nodes where they repeat.

 Two passes over the same list. The first sorts the collapsible children into
 batches by the shape they draw; the second walks the children in order and, at
 the position of a batch's *first* member, writes that batch instead. A batch is
 therefore emitted where its copies began rather than appended after everything
 else, so document order still tracks the order things were added to the scene.

 A batch of one is not a batch. It falls through to `walk` and is written as an
 ordinary node with its own name and its own tinted material, which costs no draw
 call.

 A shape whose vertices cannot be written never forms a batch at all, so its
 nodes go through `walk` and drop out there. That is what the `geometry_for` call
 in the first pass is for, and it is not wasted work: the accessors it writes are
 the ones the batch is about to reference.
*>
fn void? Exporter.place_children(&self, Node* node, List{uint}* into)
{
	// Heap-backed for `walk`'s reason: this is inside the recursion.
	List{ExportBatch} batches;
	batches.init(mem, 4);
	defer
	{
		foreach (&batch : batches) batch.members.free();
		batches.free();
	}

	foreach (child : node.children)
	{
		Node* copy = self.collapsible(child);
		if (copy == null) continue;

		int index = batch_of(&batches, copy.asset, copy.mesh, copy.material);
		if (index < 0)
		{
			if (self.geometry_for(copy.asset, copy.mesh)! < 0) continue;
			ExportBatch fresh = { .asset = copy.asset, .mesh = copy.mesh, .material = copy.material };
			fresh.members.init(mem, 8);
			batches.push(fresh);
			index = (int)batches.len() - 1;
		}
		batches.get_ref((usz)index).members.push(child);
	}

	foreach (child : node.children)
	{
		Node* copy = self.collapsible(child);
		int index = copy == null ? -1 : batch_of(&batches, copy.asset, copy.mesh, copy.material);
		if (index >= 0)
		{
			ExportBatch* batch = batches.get_ref((usz)index);
			if (batch.members.len() > 1)
			{
				if (batch.members[0] != child) continue;
				int built = self.instanced_node(batch, false)!;
				if (built >= 0) into.push((uint)built);
				continue;
			}
		}

		int built = self.walk(child)!;
		if (built >= 0) into.push((uint)built);
	}
}

<*
 Whether this node is a copy that may be folded into an instanced node.

 Returns the node itself rather than a bool, because every caller wants it and
 looking it up twice is the kind of double lookup that goes out of step.

 The exclusions are `walk`'s two — a helper, and a subtree switched off — plus
 the two instancing adds: a node with children cannot collapse, because
 instancing replicates a mesh and not a subtree, and a node with no mesh has
 nothing to instance. `walk` still applies its own, so a hidden child reaching it
 by this returning null is counted as skipped exactly once.

 @return `The node, or null if it has to be written as itself.`
*>
fn Node* Exporter.collapsible(&self, NodeId id)
{
	Node* node = self.pass.scene.node(id);
	if (node == null) return null;
	if (node.material == LINE_MATERIAL || !node.visible) return null;
	if (node.children.len() > 0) return null;
	if (!node.asset.is_set()) return null;
	if (self.pass.assets.mesh(node.asset, node.mesh) == null) return null;
	return node;
}

// The batch drawing this shape with this material, or -1. A linear scan: the
// count is the number of *distinct buckets* among one node's children, which is
// single digits in a scene anybody wrote and stays single digits in one a script
// generated — a thousand crates in six colours are six.
fn int batch_of(List{ExportBatch}* batches, AssetId asset, uint mesh, uint material) @local
{
	foreach (i, &known : batches)
	{
		if (known.asset == asset && known.mesh == mesh && known.material == material) return (int)i;
	}
	return -1;
}

<*
 Writes one batch as a single node drawing its mesh once per member.

 The node itself is at identity: instance transforms are relative to it, and it
 sits where the copies' shared parent already is, so each member's own local TRS
 goes into the arrays untouched.

 `TRANSLATION` is always written, even for the pathological batch whose copies
 are all in the same place. It is what carries the instance count — the extension
 has no length field of its own — and a reader that finds no attribute it
 recognises has been handed a node that draws an unknown number of times.
 `ROTATION`, `SCALE` and `_COLOR_0` are written only when some member differs
 from the identity, which keeps the ordinary case at twelve bytes each rather
 than forty-four.

 @param world : `Whether to take each copy's world transform rather than its local one. What a flattened export needs, because its copies no longer share a parent to be relative to.`
 @return `The document's node index, or -1 if the mesh entry could not be written.`
*>
fn int? Exporter.instanced_node(&self, ExportBatch* batch, bool world)
{
	Node* first = self.pass.scene.node(batch.members[0]);
	// Untinted, deliberately: the material is what a reader without `_COLOR_0`
	// falls back to, so it has to be the shape's own colour rather than the first
	// copy's. The tints go in the array below.
	//
	// Reading it off `members[0]` is exact rather than a sample, because the batch
	// key holds the material: every member resolves to the same surface.
	int entry = self.mesh_entry(first, NO_TINT)!;
	if (entry < 0) return -1;

	sz count = batch.members.len();
	List{Vec3} translations;
	List{Vec4} rotations;
	List{Vec3} scales;
	List{Vec4} colors;
	translations.init(mem, count);
	rotations.init(mem, count);
	scales.init(mem, count);
	colors.init(mem, count);
	defer
	{
		translations.free();
		rotations.free();
		scales.free();
		colors.free();
	}

	bool turned = false;
	bool resized = false;
	bool tinted = false;
	foreach (member : batch.members)
	{
		Node* copy = self.pass.scene.node(member);

		Vec3 position = copy.position;
		Quaternionf rotation = copy.rotation;
		Vec3 scale = copy.scale;
		if (world) decompose(copy.world, &position, &rotation, &scale);

		translations.push(position);
		rotations.push({ rotation.v[0], rotation.v[1], rotation.v[2], rotation.v[3] });
		scales.push(scale);
		colors.push({ copy.color[0], copy.color[1], copy.color[2], copy.color[3] });

		if (rotation.v[0] != 0 || rotation.v[1] != 0 || rotation.v[2] != 0 || rotation.v[3] != 1) turned = true;
		if (scale.x != 1 || scale.y != 1 || scale.z != 1) resized = true;
		if (copy.color[0] != 1 || copy.color[1] != 1 || copy.color[2] != 1 || copy.color[3] != 1) tinted = true;
	}

	gltf::WriteAttribute[4] attributes;
	usz used = 0;
	attributes[used++] = { .name = "TRANSLATION", .accessor = self.out.add_vec3(translations.array_view()) };
	if (turned)  attributes[used++] = { .name = "ROTATION",  .accessor = self.out.add_vec4(rotations.array_view()) };
	if (resized) attributes[used++] = { .name = "SCALE",     .accessor = self.out.add_vec3(scales.array_view()) };
	if (tinted)  attributes[used++] = { .name = "_COLOR_0",  .accessor = self.out.add_vec4(colors.array_view()) };

	GpuMesh* mesh = self.pass.assets.mesh(batch.asset, batch.mesh);
	uint written = self.out.add_node(mesh.name, entry, -1);
	self.out.add_instancing(written, attributes[:used]);

	self.report.nodes++;
	self.report.batches++;
	foreach (member : batch.members)
	{
		self.report.instances++;
		if (self.loses_its_shader(self.pass.scene.node(member).material)) self.report.shaded++;
	}
	return (int)written;
}

<*
 The whole scene as a handful of instanced nodes in world space.

 `walk`'s alternative, and the header says when to want it. Everything that draws
 is gathered by shape, wherever it sits in the tree, and written under one root
 that is deliberately at *identity*: the scene root's own transform is already
 inside every world matrix, and writing it again would apply it twice.

 The world matrices are recomputed first. `Node.world` is only valid after the
 walk that fills it, and an export is not a frame — a script that builds a scene
 and exports it without ever rendering has never run that walk. This is the same
 call the renderer makes, so a scene that *was* up to date pays a traversal and
 changes by nothing.

 A shape with one copy is still written as an ordinary node rather than a batch
 of one, keeping its name and its tinted material. Its transform is the world one,
 because there is no longer a parent to be relative to.

 @return `The document's root node index, or -1 for a scene with nothing to write.`
*>
fn int? Exporter.flatten_scene(&self)
{
	self.pass.scene.update_world_matrices();

	List{ExportBatch} batches;
	batches.init(mem, 8);
	defer
	{
		foreach (&batch : batches) batch.members.free();
		batches.free();
	}
	self.gather(self.pass.scene.root, &batches)!;

	List{uint} children;
	children.init(mem, batches.len() > 0 ? batches.len() : 1);
	defer children.free();

	foreach (&batch : batches)
	{
		int built = batch.members.len() > 1
			? self.instanced_node(batch, true)!
			: self.placed_node(batch.members[0])!;
		if (built >= 0) children.push((uint)built);
	}

	if (children.len() == 0) return -1;

	Node* root = self.pass.scene.node(self.pass.scene.root);
	uint written = self.out.add_node(root == null ? "" : root.name);
	foreach (child : children) self.out.add_child(written, child);
	self.report.nodes++;
	return (int)written;
}

<*
 Collects everything that draws, by shape, wherever it is in the tree.

 `walk`'s two exclusions apply unchanged, including that a hidden subtree is one
 `skipped` rather than one per node in it: the recursion stops there.

 A node that draws *and* has children contributes itself and is still descended
 into. Nothing is lost by that here — every child ends up in world space too, so
 there is no parent relationship left to preserve or to break.
*>
fn void? Exporter.gather(&self, NodeId id, List{ExportBatch}* batches)
{
	Node* node = self.pass.scene.node(id);
	if (node == null) return;

	if (node.material == LINE_MATERIAL || !node.visible)
	{
		self.report.skipped++;
		return;
	}

	if (node.asset.is_set() && self.pass.assets.mesh(node.asset, node.mesh) != null)
	{
		int index = batch_of(batches, node.asset, node.mesh, node.material);
		if (index < 0 && self.geometry_for(node.asset, node.mesh)! >= 0)
		{
			ExportBatch fresh = { .asset = node.asset, .mesh = node.mesh, .material = node.material };
			fresh.members.init(mem, 16);
			batches.push(fresh);
			index = (int)batches.len() - 1;
		}
		if (index >= 0) batches.get_ref((usz)index).members.push(id);
	}

	foreach (child : node.children) self.gather(child, batches)!;
}

<*
 One node, written where it ended up rather than where its parent put it.

 The flattened export's answer for a shape with a single copy, which is not worth
 an instancing block: one node, one name, one material carrying its tint, and the
 world transform decomposed into the TRS triple a glTF node states.

 @return `The document's node index, or -1 for a mesh whose vertices cannot be written.`
*>
fn int? Exporter.placed_node(&self, NodeId id)
{
	Node* node = self.pass.scene.node(id);
	int entry = self.mesh_entry(node, node.color)!;
	if (entry < 0) return -1;

	Vec3 position;
	Quaternionf rotation;
	Vec3 scale;
	decompose(node.world, &position, &rotation, &scale);

	uint written = self.out.add_node(node.name, entry, -1, position, rotation, scale);
	self.report.nodes++;
	self.report.instances++;
	if (self.loses_its_shader(node.material)) self.report.shaded++;
	return (int)written;
}

<*
 The `mesh` entry this node draws: its geometry, and the material its colour and
 texture resolve to.

 @param tint : `What to multiply the mesh's base colour by — the node's own colour when it is written as itself, and white for a batch, whose copies are tinted per instance instead.`
 @return `The document's mesh index, or -1 for a mesh whose vertices cannot be written.`
*>
fn int? Exporter.mesh_entry(&self, Node* node, float[4] tint)
{
	GpuMesh* mesh = self.pass.assets.mesh(node.asset, node.mesh);

	int geometry = self.geometry_for(node.asset, node.mesh)!;
	if (geometry < 0) return -1;

	// `mesh.color` multiplies albedo in the shader, and glTF's baseColorFactor
	// multiplies the base colour texture the same way — so the product is exactly
	// what the pixel was.
	//
	// The two halves are in different spaces and only one is converted.
	// `base_color` is already linear, because that is what glTF's
	// `baseColorFactor` is. The tint is `mesh.color`, a script's sRGB value, and it
	// goes through the same decode the shader applies to it. Multiplying them raw
	// means baking a stand-in colour is a choice between matching this engine and
	// matching a colour-managed viewer.
	//
	// Opacity is the third factor, for the same reason: `MeshPass.record`
	// multiplies `material.opacity()` into `base_color.a` before the draw, so the
	// alpha the file states is only the alpha the frame had if it carries all
	// three.
	Material* material_of = self.pass.material(node.material);
	float opacity = material_of == null ? 1.0f : material_of.opacity();
	float[4] linear_tint = srgb_to_linear_rgb(tint);
	float[4] color = {
		mesh.base_color[0] * linear_tint[0],
		mesh.base_color[1] * linear_tint[1],
		mesh.base_color[2] * linear_tint[2],
		mesh.base_color[3] * linear_tint[3] * opacity,
	};
	// A null material is one whose slot was collected while a node still named it,
	// which `MeshPass.record` draws as nothing at all. Every answer below has the
	// same shape for it: opaque, single-sided, the identity transform — which is
	// what every material meant before any of those existed.
	int material = self.material_for(self.surface_for(node, material_of, color)!);

	foreach (&known : self.entries)
	{
		if (known.geometry == (uint)geometry && known.material == material) return (int)known.entry;
	}

	uint written = self.out.add_mesh(mesh.name);
	ExportGeometry* streams = &self.geometry[(usz)geometry];

	gltf::WriteAttribute[4] attributes;
	usz count = 0;
	attributes[count++] = { .name = "POSITION", .accessor = (uint)streams.positions };
	if (streams.normals >= 0) attributes[count++] = { .name = "NORMAL", .accessor = (uint)streams.normals };
	if (streams.uvs >= 0) attributes[count++] = { .name = "TEXCOORD_0", .accessor = (uint)streams.uvs };
	// Written whenever the source carried one, not only when a layer reads it. That
	// is the condition the renderer uploads it on, and it is the attribute a
	// `VERTEX_COLOR` mask names — without it such a layer would come back naming
	// something the file does not have.
	if (streams.colors >= 0) attributes[count++] = { .name = "COLOR_0", .accessor = (uint)streams.colors };

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
		.colors = -1,
		.indices = (int)self.out.add_indices(streams.indices.array_view()),
	};
	// Short is absent, which is the same test `upload_primitive` applies: a normals
	// array that does not cover every vertex is one a consumer would read past the
	// end of.
	if (streams.normals.len() == streams.positions.len())
	{
		written.normals = (int)self.out.add_vec3(streams.normals.array_view());
	}
	if (streams.uvs.len() == streams.positions.len())
	{
		written.uvs = (int)self.out.add_vec2(streams.uvs.array_view());
	}
	// Float VEC4, whatever width the file stored it at. glTF allows COLOR_0 as
	// normalized bytes or shorts as well, and `@each_color` has already widened
	// whichever it was; narrowing it again to guess at the original spelling would
	// be a lossy step for the sake of a detail nothing reads back.
	if (streams.colors.len() == streams.positions.len())
	{
		written.colors = (int)self.out.add_vec4(streams.colors.array_view());
	}

	self.geometry.push(written);
	self.report.meshes++;
	return (int)self.geometry.len() - 1;
}

<*
 Whether writing this node loses something the file cannot carry.

 A `ShaderMaterial` and nothing else. Testing `node.material != DEFAULT_MATERIAL`
 instead would count a `MeshLambertMaterial` too — and glTF describes one of
 those perfectly well: a base colour, a texture and a side are exactly what a
 glTF material is. That reported `shaded: 3025` of 3029 for `examples/village`, a
 number that says "almost everything lost its shading" about a file where almost
 nothing had.

 The distinction is the fragment body: a material with one is a Slang pipeline,
 and glTF describes surfaces rather than programs.
*>
fn bool Exporter.loses_its_shader(&self, uint material)
{
	if (material == DEFAULT_MATERIAL) return false;
	if (material >= self.pass.materials.len()) return false;
	return self.pass.materials[material].fragment.len > 0;
}

<*
 Which device texture slot a node actually draws with.

 The material's map beats the mesh's own image, which is the rule
 `MeshPass.record` follows: reading `GpuMesh.texture` and never looking at the
 material means a script that put an image on a shape with
 `new three.MeshLambertMaterial({ map })` exports the shape untextured.
*>
fn int Exporter.texture_slot(&self, Node* node)
{
	if (node.material != DEFAULT_MATERIAL && node.material < self.pass.materials.len())
	{
		int mapped = self.pass.materials[node.material].texture;
		if (mapped != NO_TEXTURE) return mapped;
	}

	GpuMesh* mesh = self.pass.assets.mesh(node.asset, node.mesh);
	return mesh == null ? NO_TEXTURE : mesh.texture;
}

<*
 The exported texture this node samples, or -1.

 Keyed on the device slot — which is deduplicated by a hash of the decoded image
 across every loaded file, so two kit packs sharing an atlas write it once, and a
 `.png` on disk and the identical image inside a `.glb` are one entry in the
 written file as well as one upload on the device.

 ## Two ways to get the bytes

 From the source file, when there is one: a mesh that came from a `.glb` carries
 its image's encoded bytes in that file's buffer, and copying them across
 preserves whatever compression the artist chose — re-encoding a JPEG as a PNG
 would multiply the file size by five for no gain.

 Off the device, when there is not. A `DataTexture` has no file behind it, and
 neither does `three.texture(path)` once it is uploaded. Without this,
 `scene.export` reports `images: 0` on a scene whose entire character is eleven
 generated textures, and reloading it gives a village of flat colours. The pixels
 come back off the device and `png::save_bytes` encodes them.

 The readback is the expensive half — a queue idle per distinct texture — and it
 happens once per *device slot* rather than once per mesh, which is what the
 cache above it is for.

 The image is written without a name. A glTF image name is decorative, and the
 source file's is not readable this late: `gltf::Image.name` is a slice into the
 JSON document, which does not outlive the load. Reading it here produced nine
 bytes of fill pattern inside a JSON string and a file nothing could parse.
*>
fn int? Exporter.texture_for(&self, Node* node)
{
	int slot = self.texture_slot(node);
	if (slot < 0) return -1;

	foreach (&known : self.images)
	{
		if (known.device == slot) return (int)known.texture;
	}

	char[] encoded = {};
	gltf::ImageType mime = gltf::ImageType.IMAGE_PNG;
	bool own = false;

	// The source-file path, and only when the slot really is the one this mesh's
	// own glTF brought. A material's map is a different image entirely, and
	// reaching for the mesh's source bytes for it would write the wrong picture.
	GpuMesh* gpu_mesh = self.pass.assets.mesh(node.asset, node.mesh);
	Asset* asset = self.pass.assets.slot(node.asset);
	if (gpu_mesh != null && slot == gpu_mesh.texture && asset != null && asset.has_stream && gpu_mesh.gltf_mesh >= 0)
	{
		int source = source_image_index(asset, gpu_mesh);
		if (source >= 0)
		{
			char[]? from_file = asset.stream.get_image_data((uint)source);
			if (try from_file)
			{
				encoded = from_file;
				mime = asset.stream.gltf.images[source].mimeType;
			}
		}
	}

	if (encoded.len == 0)
	{
		char[]? made = self.encode_from_device(slot);
		if (catch made) return -1;
		encoded = made;
		own = true;
	}
	defer if (own) free(encoded);

	uint image = self.out.add_image("", encoded, mime);
	// No sampler: a texture that names none takes the viewer's default, which is
	// repeat with mipmapped linear filtering — what `Assets` uploads with.
	uint texture = self.out.add_texture(image);
	self.images.push({ .device = slot, .texture = texture });
	self.report.images++;
	return (int)texture;
}

<*
 A texture with no file behind it, read off the device and encoded as a PNG.

 PNG rather than JPEG because the pixels are exact and should stay exact: a
 generated texture is often a pattern with hard edges — a checker, a brick
 course, a tile grid — and those are what JPEG is worst at.

 @return `The encoded bytes, owned by the caller.`
*>
fn char[]? Exporter.encode_from_device(&self, int slot)
{
	Gpu* gpu = self.pass.assets.gpu;
	if (gpu == null) return EXPORT_HAS_NOTHING_TO_WRITE~;
	if (!self.pass.assets.texture_alive(slot)) return EXPORT_HAS_NOTHING_TO_WRITE~;

	Texture* texture = self.pass.assets.texture_at(slot);
	sz size = (sz)texture.width * (sz)texture.height * 4;

	char[] pixels = mem::new_array(char, size);
	defer free(pixels);
	texture.read_pixels(gpu, pixels)!;

	image::Image decoded = {
		.width = texture.width,
		.height = texture.height,
		.bit_depth = 8,
		.format = image::PixelFormat.RGBA,
		.pixels = pixels,
		.allocator = mem,
	};
	return png::save_bytes(&decoded);
}

<*
 Which material of the source file a mesh was drawn with, or -1.

 Walked from the primitive rather than remembered, because nothing the renderer
 keeps per mesh points back at the document: `GpuMesh.texture` is an index into
 the *shared* table and deliberately says nothing about which file or which
 material it came from — that is what makes it the dedup key.

 Two callers want this walk: the image lookup below, and the layer stack, which
 lives on the material and nowhere else.
*>
fn int source_material_index(Asset* asset, GpuMesh* mesh) @local
{
	if (mesh.gltf_mesh >= asset.stream.gltf.meshes.len()) return -1;
	gltf::Mesh source = asset.stream.gltf.meshes[mesh.gltf_mesh];
	if (mesh.gltf_primitive < 0 || mesh.gltf_primitive >= source.primitives.len()) return -1;

	sz? material_index = source.primitives[mesh.gltf_primitive].attributes.get("material");
	if (catch material_index) return -1;
	if (material_index >= asset.stream.gltf.materials.len()) return -1;
	return (int)material_index;
}

<*
 Which of the source file's images a mesh's base colour texture came from.
*>
fn int source_image_index(Asset* asset, GpuMesh* mesh) @local
{
	int material_index = source_material_index(asset, mesh);
	if (material_index < 0) return -1;

	int texture = asset.stream.gltf.materials[material_index].baseColorTexture.source;
	if (texture < 0 || texture >= asset.stream.gltf.textures.len()) return -1;

	int image = asset.stream.gltf.textures[texture].source;
	return image >= 0 && image < asset.stream.gltf.images.len() ? image : -1;
}

<*
 The material of the *source document* a node's mesh was drawn with, or -1.

 Where the normal, occlusion and emissive maps come from, and where an imported
 `CUSTOM_materials_layers` stack lives.

 `GpuMesh.layers` is the other candidate for the stack and is the wrong one,
 three times over. It is deliberately lossy — `Assets.load_material_layers` drops
 `metallicFactor`, `roughnessFactor`, `metallicRoughnessTexture`, `subsurface`,
 `heightTexture` and `bump`, because `lambert()` is the whole of the built-in
 light — so writing it back would state a document the file never contained. It
 is rearranged: `hoist_shared_mask` moves a mask every layer reads into a slot of
 the stack's own, which is right for the bindings budget and wrong for a file. And
 it exists only after `ensure_uploaded`, which this path deliberately never calls
 — a mesh that has been added but not yet drawn would export as a mesh with no
 layers, a wrong answer that looks like a file without the extension.

 The parsed document has none of those problems. `Assets.load` keeps the stream
 open for as long as the asset lives, so the whole material is sitting there
 already parsed, complete, and in the file's own arrangement.

 @return `The index of the material inside the asset's own document, or -1 for a mesh with no file behind it. The index rather than the material, because it is also part of the dedup key — see ExportSurface.`
*>
fn int Exporter.source_material_of(&self, Node* node)
{
	Asset* asset = self.pass.assets.slot(node.asset);
	if (asset == null || !asset.has_stream) return -1;

	GpuMesh* mesh = self.pass.assets.mesh(node.asset, node.mesh);
	if (mesh == null || mesh.gltf_mesh < 0) return -1;

	return source_material_index(asset, mesh);
}

<*
 The exported texture for one image of one source document, or -1.

 The layer half of `texture_for`, and it has only that function's *first* source:
 the bytes come out of the file the layer was read out of. There is no fallback
 to a device readback, because there is nothing to read back — a layer's images
 reach the device through slots this path cannot walk back to.

 @param image : `Index into the source document's images array.`
*>
fn int Exporter.layer_texture_for(&self, AssetId id, int image)
{
	if (image < 0) return -1;

	foreach (&known : self.layer_images)
	{
		if (known.asset == id && known.image == image) return (int)known.texture;
	}

	Asset* asset = self.pass.assets.slot(id);
	if (asset == null || !asset.has_stream) return -1;
	if (image >= asset.stream.gltf.images.len()) return -1;

	char[]? encoded = asset.stream.get_image_data((uint)image);
	if (catch encoded) return -1;
	if (encoded.len == 0) return -1;

	uint written = self.out.add_image("", encoded, asset.stream.gltf.images[image].mimeType);
	// No sampler, for the reason `texture_for` gives: a texture that names none
	// takes the viewer's default, which is what `Assets` uploads with.
	uint texture = self.out.add_texture(written);
	self.layer_images.push({ .asset = id, .image = image, .texture = texture });
	self.report.images++;
	return (int)texture;
}

<*
 Turns one parsed stack back into a written one, image indices and all.

 The one place the two vocabularies meet. A parsed `TextureInfo.source` is an
 *image* index — `layer_texture` resolved it through the textures array on the
 way in — while a written one is a *texture* index, so every slot goes through
 `layer_texture_for`, which is what allocates the texture in the output document.
 `gltf.c3l`'s writer has structs of its own precisely so this conversion cannot
 be skipped by accident.

 The transform rides along unchanged: it is `KHR_texture_transform`, which the
 parser reads off the same object and neither side interprets.
*>
fn void Exporter.write_layers(&self, uint material, AssetId id, gltf::MaterialLayers* source)
{
	uint stack = self.out.add_material_layers(
		material,
		self.write_layer_texture(id, source.heightTexture),
		source.bump
	);

	foreach (&layer : source.layers)
	{
		gltf::WriteMaterialLayer written = gltf::material_layer(layer.name);
		written.baseColorFactor = layer.baseColorFactor;
		written.metallicFactor = layer.metallicFactor;
		written.roughnessFactor = layer.roughnessFactor;
		written.baseColorTexture = self.write_layer_texture(id, layer.baseColorTexture);
		written.metallicRoughnessTexture = self.write_layer_texture(id, layer.metallicRoughnessTexture);
		written.normalTexture = self.write_layer_texture(id, layer.normalTexture);
		written.heightTexture = self.write_layer_texture(id, layer.heightTexture);
		written.bump = layer.bump;
		written.emissiveFactor = layer.emissiveFactor;
		written.emissiveTexture = self.write_layer_texture(id, layer.emissiveTexture);
		written.subsurface = layer.subsurface;
		written.mask = {
			.source = layer.mask.source,
			.channel = layer.mask.channel,
			.texture = self.write_layer_texture(id, layer.mask.texture),
			.attribute = layer.mask.attribute,
			.invert = layer.mask.invert,
		};
		written.blend_mode = layer.blend_mode;
		written.opacity = layer.opacity;
		written.enabled = layer.enabled;

		self.out.add_layer(stack, written);
		self.report.layers++;
	}
}

fn gltf::WriteTextureRef Exporter.write_layer_texture(&self, AssetId id, gltf::TextureInfo info)
{
	gltf::WriteTextureRef written = gltf::texture_ref(self.layer_texture_for(id, info.source));
	written.rotation = info.rotation;
	written.offset = info.offset;
	written.scale = info.scale;
	return written;
}

<*
 Whether the material this node draws with is a `three.LayeredMaterial`, and its
 index if it is.

 The other half of `source_material_of`. A stack a *script* wrote has no source
 document to be read out of, so it is read from `Material.script_layers`, the
 description `js/prelude/layers.js` sends across at construction.

 This beats an imported stack when a node has both, which is the rule
 `texture_slot` already follows one function up: the material is what the frame
 drew with. A script that loads a layered terrain and then puts its own
 `LayeredMaterial` on it has replaced the stack.

 @return `The index into MeshPass.materials, or -1. The index rather than the stack, because it is also the dedup key — see ExportMaterial.`
*>
fn int Exporter.script_material_index(&self, Node* node)
{
	Material* material = self.pass.material(node.material);
	if (material == null) return -1;
	return material.script_layers.present && material.script_layers.layers.len() > 0
		? (int)node.material
		: -1;
}

<*
 A script's stack, written out.

 The mirror of `write_layers`, and the differences are all consequences of where
 the description came from.

 No height map and no bump, because `LayeredMaterial` refuses both by name —
 there is no parallax in this renderer, so a script cannot state one. The same
 goes for the PBR half: `metalness` and `roughness` are refused because nothing
 evaluates them. That is why this is lossless where writing `GpuLayers` back
 would not be: the description is the whole of what the script said, not a
 reduction of a file.

 The tint and the opacity are read now, not remembered. `Material.layer_params`
 answers with the shader's baked literals for a plain layer and with the live
 push block for one that asked to be `animated`, so a tint a script has been
 animating exports as whatever it is at the moment of the export.

 The tint goes into `baseColorFactor.rgb` with an alpha of 1 and the opacity into
 the extension's own `opacity` beside it. The importer multiplies the two, so
 that round-trips to the numbers that went in — putting the opacity in the alpha
 instead would come back the same in the product and wrong in both fields.

 Every layer here is enabled: `LayeredMaterial` drops `enabled: false` before it
 generates anything, so a disabled layer never reaches the host.
*>
fn void Exporter.write_script_layers(&self, uint material, Material* source)
{
	uint stack = self.out.add_material_layers(material);
	int shared_mask = source.textures.at(source.script_layers.mask_binding);

	foreach (&layer : source.script_layers.layers)
	{
		float[4] params = source.layer_params(layer);

		gltf::WriteMaterialLayer written = gltf::material_layer(layer.name);
		written.baseColorFactor = { params[0], params[1], params[2], 1.0 };
		written.opacity = params[3];
		written.baseColorTexture = self.script_layer_texture(source, layer.map_binding);
		written.normalTexture = self.script_layer_texture(source, layer.normal_binding);
		written.emissiveTexture = self.script_layer_texture(source, layer.emissive_binding);
		written.emissiveFactor = {
			layer.emissive_factor[0], layer.emissive_factor[1], layer.emissive_factor[2]
		};
		written.blend_mode = (gltf::LayerBlendMode)layer.blend_mode;
		written.mask = {
			.source = (gltf::LayerMaskSource)layer.mask_source,
			.channel = (gltf::LayerMaskChannel)layer.mask_channel,
			// A layer with no mask sampler of its own reads a channel of the stack's
			// shared one, which is the arrangement the generator produces and the one
			// the extension's per-layer `channel` field exists for. Written per layer
			// because that is how the file spells the sharing — several layers naming
			// one textureInfo — which is what `hoist_shared_mask` undoes on the way
			// back in.
			.texture = layer.mask_binding != 0
				? self.script_layer_texture(source, layer.mask_binding)
				: gltf::texture_ref(self.device_texture_for(shared_mask)),
			.attribute = "",
			.invert = layer.invert,
		};
		written.enabled = true;

		self.out.add_layer(stack, written);
		self.report.layers++;
	}
}

fn gltf::WriteTextureRef Exporter.script_layer_texture(&self, Material* source, uint binding)
{
	return gltf::texture_ref(self.device_texture_for(source.textures.at(binding)));
}

<*
 The exported texture for a device slot, read back off the device.

 `texture_for`'s second source on its own, because a script's image has no first:
 a `LayeredMaterial`'s maps are `three.texture(path)` and `DataTexture` handles,
 which go straight into the shared table with no file behind them.

 It shares `texture_for`'s memo rather than the layer one, and that is the point:
 the key is the device slot, which is already content-deduplicated, so a stack
 whose base map and whose first layer sample one image write it once. The layer
 memo exists for the *imported* path, where there is no device slot to key on.

 @return `The document's texture index, or -1 when there is no device, the slot is dead, or the readback failed.`
*>
fn int Exporter.device_texture_for(&self, int slot)
{
	if (slot < 0) return -1;

	foreach (&known : self.images)
	{
		if (known.device == slot) return (int)known.texture;
	}

	char[]? encoded = self.encode_from_device(slot);
	if (catch encoded) return -1;
	defer free(encoded);

	uint image = self.out.add_image("", encoded, gltf::ImageType.IMAGE_PNG);
	uint texture = self.out.add_texture(image);
	self.images.push({ .device = slot, .texture = texture });
	self.report.images++;
	return (int)texture;
}

<*
 The glTF material one surface needs, written once per distinct surface.

 `ExportSurface` is both the argument and the dedup key, and says why it is the
 whole of it.
*>
fn int Exporter.material_for(&self, ExportSurface surface)
{
	foreach (&known : self.materials)
	{
		if (known.key.equals(surface)) return (int)known.material;
	}

	// Fully rough and not metallic: `mesh.slang` is a Lambert term and a texture,
	// with no specular of any kind, so a metallic material would render in a glTF
	// viewer as something this never showed.
	//
	// `BLEND` rather than `MASK`, because that is what this renderer does: the
	// alpha is a blend factor, not a cutoff, and `alpha_cutoff` is left at its
	// default because `BLEND` does not read it. An opaque material stays `OPAQUE`
	// rather than being written as `BLEND` with an alpha of 1 — the two render the
	// same and only one of them tells a viewer it may skip the sort.
	uint written = self.out.add_material(
		"",
		{ surface.base_color[0], surface.base_color[1], surface.base_color[2], surface.base_color[3] },
		metallic: 0.0,
		roughness: 1.0,
		base_color_texture: uv_texture_ref(surface.texture, surface.uv_transform),
		double_sided: surface.double_sided,
		alpha_mode: surface.transparent ? gltf::AlphaMode.BLEND : gltf::AlphaMode.OPAQUE,
	);
	self.out.set_material_maps(
		written,
		normal: surface.normal,
		occlusion: surface.occlusion,
		emissive: surface.emissive,
		emissive_factor: {
			surface.emissive_factor[0], surface.emissive_factor[1], surface.emissive_factor[2]
		}
	);

	// After `add_material`, because the stack hangs off the material that was just
	// added and `add_material_layers` takes its index.
	if (surface.script_material >= 0)
	{
		Material* source = self.pass.material((uint)surface.script_material);
		if (source != null) self.write_script_layers(written, source);
	}
	else if (surface.layers_material >= 0)
	{
		Asset* asset = self.pass.assets.slot(surface.layers_asset);
		if (asset != null && asset.has_stream && surface.layers_material < asset.stream.gltf.materials.len())
		{
			self.write_layers(
				written, surface.layers_asset,
				&asset.stream.gltf.materials.get_ref((usz)surface.layers_material).layers_ext
			);
		}
	}

	self.materials.push({ .key = surface, .material = written });
	self.report.materials++;
	return (int)written;
}

<*
 Everything about a node that decides its glTF material, resolved.

 The maps are resolved here rather than in `material_for`, which is what lets the
 dedup key be what gets written. Resolving one writes its image into the document
 on the first call and answers from the memo afterwards, so doing it before the
 dedup check costs nothing: an image any material references has to be in the
 file, and two materials that turn out to be one reference the same one.

 The script's material wins over the source document's. A node drawing a file's
 mesh under its own `LayeredMaterial` shows the script's stack and the script's
 base normal; writing the file's would be a picture the frame did not draw.

 Not the metallic-roughness map, and not the two factors: this renderer has no
 specular term, so those describe an equation nothing evaluates.
*>
fn ExportSurface? Exporter.surface_for(&self, Node* node, Material* material_of, float[4] color)
{
	ExportSurface surface = {
		.base_color = color,
		.texture = self.texture_for(node)!,
		// A null material is one whose slot was collected while a node still named
		// it, which `MeshPass.record` draws as nothing at all. Every answer here has
		// the same shape for it — opaque, single-sided, the identity transform.
		.uv_transform = material_of == null ? UV_IDENTITY : material_of.uv_transform_or_identity(),
		.transparent = material_of != null && material_of.blend != BlendMode.NONE,
		.double_sided = material_of != null && material_of.cull == CULL_MODE_NONE,
		.normal = gltf::NO_TEXTURE_REF,
		.occlusion = gltf::NO_TEXTURE_REF,
		.emissive = gltf::NO_TEXTURE_REF,
		.layers_asset = NO_ASSET,
		.layers_material = -1,
		.script_material = self.script_material_index(node),
	};

	if (surface.script_material >= 0)
	{
		Material* script = self.pass.material((uint)surface.script_material);
		if (script != null)
		{
			surface.normal = gltf::texture_ref(
				self.device_texture_for(script.textures.at(script.script_layers.base_normal_binding))
			);
		}
		return surface;
	}

	int source_material = self.source_material_of(node);
	if (source_material < 0) return surface;

	Asset* asset = self.pass.assets.slot(node.asset);
	gltf::Material* source = asset.stream.gltf.materials.get_ref((usz)source_material);
	surface.normal = self.source_texture_ref(node.asset, source.normalTexture);
	surface.occlusion = self.source_texture_ref(node.asset, source.occlusionTexture);
	surface.emissive = self.source_texture_ref(node.asset, source.emissiveTexture);
	surface.emissive_factor = {
		source.emissiveFactor.x, source.emissiveFactor.y, source.emissiveFactor.z
	};
	if (source.has_layers())
	{
		surface.layers_asset = node.asset;
		surface.layers_material = source_material;
	}
	return surface;
}

// A source document's textureInfo as a written one: its image resolved to an
// output texture, its `KHR_texture_transform` carried across untouched.
fn gltf::WriteTextureRef Exporter.source_texture_ref(&self, AssetId id, gltf::TextureInfo info)
{
	gltf::WriteTextureRef written = gltf::texture_ref(self.layer_texture_for(id, info.source));
	written.rotation = info.rotation;
	written.offset = info.offset;
	written.scale = info.scale;
	return written;
}

<*
 A base colour map carrying `material.repeat` and `material.offset`.

 The renderer applies these in the fragment stage before a material body runs, so
 they are part of what the frame showed and belong in the file.
 `KHR_texture_transform` is the only place core glTF has for them — without it a
 tiling floor exports with its texture stretched once across the whole surface.

 `Material.uv_transform_or_identity` has already turned the all-zero "unset" into
 the identity, and the identity writes no extension.
*>
fn gltf::WriteTextureRef uv_texture_ref(int texture, float[4] uv_transform) @local
{
	gltf::WriteTextureRef written = gltf::texture_ref(texture);
	written.scale = { uv_transform[0], uv_transform[1] };
	written.offset = { uv_transform[2], uv_transform[3] };
	return written;
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
 Re-reads a primitive out of the file it was loaded from.

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
	// Set 0 only. `CUSTOM_materials_layers` lets a mask name an attribute, and every
	// attribute it can name that this renderer reads is COLOR_0 —
	// `Assets.load_material_layers` uploads one colour stream per mesh.
	asset.stream.@each_color(primitive, 0; Vec4 color, sz i) { out.colors.push(color); };

	read_indices(&asset.stream, primitive, &out.indices);
	// A primitive with no index accessor is a plain vertex list, and glTF lets a
	// primitive be written the same way — but the writer's dedup and the reader's
	// bucket both key on an index accessor being there.
	if (out.indices.len() == 0)
	{
		for (uint i = 0; i < out.positions.len(); i++) out.indices.push(i);
	}
	return true;
}

<*
 A hull, out of the CPU copy the picking tree holds.

 Its normals and its uvs are recomputed rather than stored, and that is exact
 rather than approximate: `build_convex` splits a vertex per face, so every
 vertex here belongs to exactly one triangle. The accumulated normal is therefore
 that triangle's, and the uv is that triangle's own planar projection through the
 same `face_basis` the builder used.

 Two passes over the triangles rather than one, because the uv needs a *unit*
 normal and the normals are only unit after the accumulate. The cost is one more
 walk of a list that is already in cache; the alternative is normalising each
 face twice.
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

	// Now that the normals are unit, the projection. A vertex no triangle reached
	// keeps (0, 0) — it has no face and therefore no plane to be projected onto,
	// and it is also not in the index buffer, so nothing will sample it.
	foreach (position : mesh.hull_positions) out.uvs.push({ 0, 0 });
	foreach (triangle : mesh.hull_triangles)
	{
		foreach (corner : triangle)
		{
			if (corner >= out.positions.len()) continue;
			Vec3 normal = out.normals[corner];
			if (normal.length() < 0.5f) continue;
			Vec3 tangent;
			Vec3 bitangent;
			face_basis(normal, &tangent, &bitangent);
			Vec3 at = out.positions[corner];
			out.uvs[corner] = { at.dot(tangent), at.dot(bitangent) };
		}
	}
	return out.indices.len() >= 3;
}

<*
 The camera, as a glTF camera on a node of its own.

 Without this an exported scene opens wherever the viewer decides, which for most
 viewers is a framing of the bounding box — so a scene composed for a particular
 angle arrives pointing somewhere else.

 The orbit camera reduces to a placement cleanly: `Camera.eye` is where it is and
 `Camera.orbit_dir` is the direction from the target back to the eye, which is
 the node's +Z — because a glTF camera looks down *-Z*, and -Z is therefore the
 direction from the eye toward the target.

 `fov` is degrees here and radians in the file; `aspectRatio` is deliberately not
 written, which tells a viewer to use its own viewport rather than letterboxing
 to whatever the offscreen target happened to be.
*>
fn void Exporter.write_camera(&self)
{
	Camera* camera = &self.pass.camera;

	uint written = self.out.add_camera(
		"camera",
		math::deg_to_rad(camera.fov),
		camera.near_plane,
		zfar: camera.far_plane
	);
	uint node = self.out.add_node(
		"camera",
		translation: camera.eye(),
		rotation: rotation_towards(camera.orbit_dir())
	);
	self.out.set_node_camera(node, written);
	self.out.add_root(node);
	self.report.nodes++;
}

<*
 The light, as a directional `KHR_lights_punctual` on a node of its own.

 `MeshPass.light` is `float[4]`: xyz is the *surface-to-light* direction and w is
 the ambient floor. A glTF directional light shines along its node's -Z, and the
 direction light *travels* is the negation of surface-to-light — so the node's +Z
 is the vector as stored, and no negation appears here at all. Getting that
 backwards lights the far side of everything, which reads as the exporter having
 the normals wrong.

 The ambient floor cannot be written. `KHR_lights_punctual` has no ambient light
 — it was removed from the extension before ratification — and there is no other
 standard slot for one. A scene with a high floor therefore reloads darker in a
 viewer than it looked here. Folding it into the directional light's intensity
 would be a different picture rather than the same one.

 White at intensity 1 because three's light has neither a colour nor a strength
 of its own — the direction is the whole of it.
*>
fn void Exporter.write_light(&self)
{
	Vec3 to_light = { self.pass.light[0], self.pass.light[1], self.pass.light[2] };
	// A light of zero length points nowhere, and normalising it would put NaNs into
	// the node's rotation. Nothing is written rather than something wrong.
	if (to_light.length() < 1e-6f) return;

	uint written = self.out.add_light("light", gltf::LightType.DIRECTIONAL);
	uint node = self.out.add_node("light", rotation: rotation_towards(to_light.normalize()));
	self.out.set_node_light(node, written);
	self.out.add_root(node);
	self.report.nodes++;
}

<*
 The rotation that puts a node's +Z along `forward`.

 Both callers want the same thing and neither wants a full look-at: a camera and
 a directional light are aimed by their -Z, so the vector handed in is already
 the +Z and the basis is completed around it.

 The up axis flips near the pole for `Camera.pitch`'s reason: with `up` parallel
 to `forward` the cross product is zero, the basis is degenerate and the
 quaternion comes back full of NaN. Nothing errors — the camera simply renders
 nothing — so the case is handled rather than asserted.
*>
fn Quaternionf rotation_towards(Vec3 forward) @local
{
	Vec3 up = math::abs(forward.y) > 0.999f ? (Vec3) { 0, 0, 1 } : (Vec3) { 0, 1, 0 };
	Vec3 x = up.cross(forward).normalize();
	Vec3 y = forward.cross(x);
	return quat_from_basis(x, y, forward);
}
