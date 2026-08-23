<*
 Loaded glTF files: meshes uploaded once, textures deduplicated across all of
 them.

 Three decisions here are cheap now and expensive later:

 - **One uploaded mesh per glTF primitive. Never a soup.** crig's
   `gltf/source.c3` deliberately welds a whole scene into a single triangle
   soup, because a rigger wants one mesh. three.c3 wants the exact opposite: the
   thesis is that an instance is an immutable asset reference plus a transform,
   so `Scene` has to be able to name a mesh and place N copies of it.

 - **Textures deduplicated by content hash across every asset already loaded**
   (`plan.md` §2), not merely within one file. Two kit pieces exported from the
   same source share their images, and the whole point is that a scene built out
   of a kit uploads each image once. That is why the texture list and the 1x1
   white stand-in live on `Assets` rather than on `Asset`.

 - **A `TriBVH` per unique mesh, built at upload.** It is not read until
   `scene/pick.c3` needs it, but it is per *mesh* rather than per instance —
   a thousand copies of a wall cost one tree — and building it here is what makes
   that true without a second pass over the file. The cost is honest and worth
   stating: the positions and a triangle index array stay resident on the CPU
   for the life of the asset, because the tree points at them.

 ## There are no descriptor pools

 There were, until M5: one pool sized for exactly the textures a single `load`
 added, plus a one-set pool for the white stand-in, with a `sets` list running
 parallel to `textures`. All of it is gone. `VK_KHR_push_descriptor` lets the
 draw loop specify the image and sampler inline in the command buffer, so there
 is no set to allocate, no pool to size, and no lifetime to keep in step with the
 texture list.

 What that bought is not the deleted code, it is the deleted *coupling*:
 `Assets.load` used to take a `MeshPipeline*` for the sole purpose of allocating
 sets against its descriptor layout, which meant the asset table knew what a
 pipeline was and every texture set was bound to one particular layout. Materials
 made that actively uncomfortable — a set baked against the mesh pipeline's
 layout, bound into a material pipeline's, is legal only by an argument about
 layout compatibility that a future shader could quietly break. Now the question
 does not arise.

 The extension is required, not probed-and-worked-around, exactly as
 `VK_KHR_dynamic_rendering` is: `Gpu.limits.push_descriptor` is queried and a
 device without it is refused with a sentence. Both are baseline on every driver
 this targets.
*>
module three;

import std::io;
import std::io::file;
import std::collections::list;
import std::math;
import std::math::vector;
import std::math::matrix;
import std::math::quaternion;
import vk;
import gltf;
import image;
import image::png;
import image::jpeg;
import collision;

faultdef
	ASSET_HAS_NO_MESHES,
	UNSUPPORTED_IMAGE,
	TEXTURE_UNREADABLE,
	TEXTURE_FORMAT_UNKNOWN,
	TEXTURE_BIT_DEPTH;

<*
 A handle to a loaded asset: which slot, and which occupant of it.

 The same two fields as `NodeId` (`scene/node.c3`), for the same reason and by
 deliberate mirroring. Until G2 an asset index was a promise the table never
 broke — nothing was ever freed, so slot 7 meant one file forever and a bare
 `uint` was the whole truth. Unloading breaks that promise: slot 7 is handed to
 the next load, and a script still holding the old index would place somebody
 else's mesh with nothing anywhere reporting an error.

 The generation is what turns that silence into a sentence. `free_slot` climbs
 it, so `Assets.slot` can tell "the asset that is there now" from "the asset that
 was there when you asked", and the verb that asked says the asset was unloaded.

 Nothing in the renderer compares generations in a hot loop: `bucket_key` packs
 the index alone, because two *live* nodes naming the same slot necessarily agree
 about its generation — an asset with a live node has a non-zero refcount and is
 never swept.
*>
struct AssetId
{
	uint index;
	uint generation;
}

const AssetId NO_ASSET = { uint::max, 0 };

fn bool AssetId.is_set(self) => self.index != uint::max;
fn bool AssetId.equals(self, AssetId other) @operator(==) => self.index == other.index
	&& self.generation == other.generation;

<*
 One layer of `CUSTOM_materials_layers`, resolved to texture slots.

 The extension's `MaterialLayer` as this renderer can actually use it, which is
 deliberately less than the file carries: the PBR half — metallic, roughness,
 subsurface — is dropped here rather than stored, because `lambert()` is the whole
 of the built-in light and `plan.md` §12 is explicit that a field nothing evaluates
 is worse than an absence. Height and bump go the same way and for the same reason.
 What is left is what the generated shading body reads.

 The texture fields are indices into `Assets.textures`, or -1, and **each holds one
 reference for as long as this record does** — released by `GpuMesh.release_layers`
 beside the base colour map's own release. `mask_texture` is -1 when the layer reads
 a channel of the material's shared mask instead of carrying one of its own.
*>
struct GpuLayer
{
	String name; // owned
	float[4] base_color;
	float[3] emissive_factor;
	int texture;
	int normal_texture;
	int emissive_texture;
	int mask_texture;
	// The extension's `LayerBlendMode` and `LayerMaskChannel` ordinals, passed
	// through to the JS side as numbers and turned into names there. Kept as the
	// enum's own numbering rather than re-spelled, so the two ends cannot drift.
	uint blend_mode;
	uint mask_channel;
	// `LayerMaskSource.NONE` for a layer with no mask, which is visible everywhere.
	// A `VERTEX_COLOR` mask survives to here as itself rather than being dropped:
	// the JS side refuses it by name, and it can only do that if it is told.
	uint mask_source;
	float opacity;
	bool invert;
	bool enabled;
}

<*
 A material's whole layer stack, as one mesh resolved it.

 `present` is false for the overwhelming majority of meshes — every primitive whose
 material never carried the extension — and everything else is then empty, so this
 costs a bool on a struct that already has fifteen fields.

 **Resolved per `GpuMesh` rather than per glTF material**, which is the decision
 worth stating. Several primitives may share one material, and resolving once per
 material would be fewer walks; it would also mean a stack outliving the meshes that
 named it, a second refcount to say when it may go, and a lifetime that is not the
 one `GpuMesh.texture` already has. Per mesh, each primitive holds its own
 references to the same slots exactly as it already does for the base colour map,
 and `ImageMemo` still collapses the *uploads* — which is where the cost actually
 was.
*>
struct GpuLayers
{
	bool present;
	// The material's shared mask, sampled once and read by channel. -1 when every
	// layer carries its own or none of them has one. Holds a reference like the
	// per-layer textures do.
	int mask_texture;
	List{GpuLayer} layers;
}

<*
 One glTF primitive, uploaded.

 A glTF *mesh* is a list of primitives, each with its own material, and the
 renderer's unit of work is the primitive rather than the mesh — so this is what
 the instance table keys on. The mesh's name is carried on every primitive it
 produced so a mesh can still be found by name.
*>
struct GpuMesh
{
	// **Owned.** `gltf::Mesh.name` is freed by `GltfStream.close`, so keeping
	// the pointer would leave every mesh named by freed memory — invisible until
	// something actually reads a name, which is exactly what `Assets.find_mesh`
	// does.
	String name;

	// Streams, tightly packed. `positions` is the only one that must exist.
	vk::Memory positions;
	vk::Memory normals;
	vk::Memory uvs;
	vk::Memory indices;
	uint vertex_count;
	uint index_count;
	bool has_normals;
	bool has_uvs;
	float[4] base_color;
	// Index into `Assets.textures`, or -1 for "no texture": the material samples
	// the shared 1x1 white image instead.
	int texture;
	// `CUSTOM_materials_layers`, if this primitive's material carried it. Empty
	// and `present == false` otherwise, which is every mesh in every file that
	// was not authored with the extension — see `GpuLayers`.
	//
	// **Unlike `texture`, the zero fill is correct here**, because the field that
	// decides whether anything is read is a bool rather than an index: a
	// construction site that forgets this gets `present == false` and a mesh with
	// no stack, which is exactly what a mesh with no stack should be. That is the
	// second of the three strategies `scene/material.c3`'s header lays out —
	// encode "unset" as a value that cannot be confused with a real one.
	GpuLayers layers;
	collision::Aabb3 bounds;

	// Picking, in mesh-local space. The tree holds raw pointers into the two
	// arrays beside it, so all three live and die together.
	Vec3[] hull_positions;
	collision::Triangle[] hull_triangles;
	collision::TriBVHNode* bvh;

	// ---- Lazily uploaded, since G3/S3 ------------------------------------
	//
	// `Assets.load` describes a file rather than uploading it, so a mesh slot
	// exists from the moment the JSON is parsed and everything above this line
	// except `name`, `bounds` and `vertex_count` is empty until something draws
	// it. Those three come out of the JSON: a POSITION accessor's `count` and
	// its required `min`/`max`, which is the same reading `inventory.c3` does.

	// How many live nodes name this mesh. **Per mesh rather than per file**,
	// which is what lets one unused piece of a kit go while its neighbours stay
	// — `Scene.create_slot` and `Scene.kill` maintain it, the same two places
	// that maintain `Asset.refs`, which is now the sum of these.
	uint refs;

	// Whether the streams above are on the device. A mesh with `refs > 0` and
	// `uploaded == false` is one whose upload failed; it draws nothing and does
	// not pick, which is the same answer a material whose texture would not
	// decode gets, and for the same reason.
	bool uploaded;

	// Where to read it from when that happens: indices into the file's own
	// `meshes` and that mesh's `primitives`. Meaningless for a generated shape,
	// which has no file and is uploaded at the moment it is built.
	int gltf_mesh;
	int gltf_primitive;
}

<*
 One copy placed by `EXT_mesh_gpu_instancing`: where it sits relative to the node
 carrying it, and the tint it draws with.

 The tint is the extension's `_COLOR_0`, an application-specific attribute read
 by the same instance index as the transforms — see `scene/export.c3` for the
 half that writes it. A file that has transforms and no colours leaves this white
 for every copy, which is the identity `Node.color` already multiplies by, so
 nothing downstream has to know which kind of file it came from.
*>
struct AssetInstance
{
	Vec3 position;
	Quaternionf rotation;
	Vec3 scale;
	float[4] color;
}

<*
 One glTF node: a local transform, the meshes it draws, and its children.

 **The thing `Assets.load` used to throw away.** Until G3 the loader produced a
 flat list of primitives and `MeshPass.place` dropped every one of them at the
 origin, which is correct for a file that bakes its transforms into the vertices
 and silently wrong for one that does not — a kit exported with each piece
 positioned by its node renders as a heap. Nothing caught it because both
 fixtures had identity nodes.

 Two other things need this and neither could have it: `asset.instantiate()`
 wants a hierarchy to instantiate, and a glTF animation channel addresses a
 **node index**, so without the tree there is nothing for G3/S4 to animate.

 Transforms are stored decomposed rather than as the matrix, because that is what
 a `three::Node` holds and what an animation channel writes into. glTF lets a
 node state either a matrix or a TRS triple; `local_matrix` resolves that, and
 this decomposes the result — one path rather than two, at the cost of a
 round-trip through a matrix for the TRS case that is exact to float precision.
*>
struct AssetNode
{
	String name; // owned

	Vec3 position;
	Quaternionf rotation;
	Vec3 scale;

	// The copies `EXT_mesh_gpu_instancing` placed on this node, or empty for the
	// ordinary node that draws once. Owned. `flatten` turns each of these into an
	// entry of its own, so nothing past that walk has to know the difference
	// between a file that instanced its crates and one that listed them.
	List{AssetInstance} instances;

	// The half-open range of `Asset.meshes` this node draws. A glTF *mesh* is a
	// list of primitives and every primitive became its own `GpuMesh`, so a node
	// naming one glTF mesh can draw several — which is why this is a range and
	// not an index. `mesh_count == 0` is a group.
	uint first_mesh;
	uint mesh_count;

	// Indices into `Asset.nodes`. Owned.
	List{uint} children;
}

struct Asset
{
	String path; // owned
	List{GpuMesh} meshes;
	collision::Aabb3 bounds;

	// The file's node hierarchy, and the indices into it that nothing is a child
	// of. Empty for an asset with no nodes at all — a generated primitive, or a
	// glTF that declares meshes and no scene — and `Assets.flatten` falls back
	// to listing the meshes flat when it is.
	List{AssetNode} nodes;
	List{uint} roots;

	// How a generated shape was described, for the exporter and for nothing else.
	// `Primitive.build` regenerates its positions, normals and uvs from these
	// eight numbers, which is why they are kept and the CPU streams are not —
	// thirty-two bytes per asset against twenty per vertex. `has_primitive` is
	// false for a file, a convex hull and a line shape; `scene/export.c3` says
	// what each of those does instead.
	Primitive primitive;
	bool has_primitive;

	// The file, still open. `Assets.load` parses the JSON and stops, so the
	// document and its mmapped buffer have to stay until the last mesh in them
	// is uploaded or the asset is freed — which is what `game.md` G3/S3 calls
	// the real work in the step, and it is this field plus `free_slot` closing
	// it. `has_stream` is false for a generated shape, which never had a file.
	gltf::GltfStream stream;
	bool has_stream;

	// The decode memo, which now outlives one `load` for the same reason the
	// stream does: two meshes sharing a material may be uploaded an hour apart.
	List{ImageMemo} images;

	// The file's animation clips, named and measured at load and with their
	// curves read on first play — `scene/animation.c3`. On the asset because
	// keyframes are immutable data a hundred copies of a character share; the
	// *player* is per instance and lives on `Scene`.
	List{AnimationClip} clips;

	// The number of live `Mesh` nodes pointing here (`plan.md` §2), maintained
	// by `Scene.create_slot` and `Scene.kill` — the two places a node can start
	// or stop naming an asset — so that there is one implementation of it
	// rather than one per caller.
	//
	// **Zero means unloadable, and it means it completely.** In Three.js you
	// need an explicit `.dispose()` because anything can hold a hidden reference
	// to a buffer; here nothing can, because there is no accessor from an asset
	// to its data. That is the same refusal that made every expressible scene
	// one draw call per mesh, paying for a second thing.
	uint refs;

	// Slot bookkeeping, mirroring `Node`. `generation` climbs when the slot is
	// freed, which is what makes every outstanding `AssetId` to it stale.
	uint generation;
	bool alive;
}

fn collision::Aabb3 Asset.aabb(&self) => self.bounds;

<*
 A deduplicated texture, and how many `GpuMesh`es name it.

 The count is what lets an image outlive the file that first uploaded it and die
 with the last file that uses it — which is the case that actually happens,
 because the dedup is across *files*: two kit pieces share an image, one of them
 unloads, and the image has to stay for the other.

 Wrapped rather than counted in a second list beside `textures`. The header
 above says there is nothing parallel to the texture list any more, and a
 refcount array running alongside it would put that back — the exact shape the
 descriptor-set list had, and the exact way it went wrong.
*>
struct SharedTexture
{
	Texture texture;
	uint refs;
	bool alive;
}

<*
 One open file's decoded images: a glTF image index, and the `Assets.textures`
 slot it ended up in.

 `load_material_texture` is called once per *primitive*, and the content-hash
 dedup that stops a duplicate upload only runs after the PNG has been decoded,
 converted to RGBA and hashed. So a kit atlased into one image and cut into two
 hundred pieces decoded that image two hundred times and uploaded it once —
 correct output, and all of the work. This is the index consulted before the
 decoder rather than after it.

 It does not replace the hash. The hash answers a question this cannot see:
 two *different* images, in the same file or in different files, that happen to
 hold the same picture. This one only knows about a file's own indices, which is
 exactly why it is cheap enough to check first.

 `texture` is -1 for an image the decoder refused, and that is worth memoising
 too — a file whose ninety materials all name one KTX2 image should attempt the
 decode once, not ninety times.

 ## The colourspace is part of the key, and it has to be

 `claim_texture` says it plainly: the same PNG asked for as `SRGB` and as `LINEAR`
 is two images in two Vulkan formats, because the space is the format rather than
 a setting on it. So the same glTF image used as a base colour map by one material
 and as a layer's *mask* by another is genuinely two uploads.

 A memo keyed on the image index alone would answer the second caller with the
 first one's slot — and the picture would be right, so nothing would look wrong
 until a weight read 0.21 where the file stored 0.5 and every layer came out
 faint. That is the same failure `mapped_normal`'s header warns about for normal
 maps, arriving through a cache instead of through a script.
*>
struct ImageMemo
{
	int image;
	ColorSpace space;
	int texture;
}

<*
 What one call to `unload_unused` gave back.

 Reported rather than merely done, because an agent that cannot watch the number
 go down has no way to believe any of this works — `game.md` G2/S6. The bytes are
 texture bytes, which is the half that actually moves the device's memory number;
 `texture_bytes` computes it the same way `stats()` does, so the two agree.
*>
struct UnloadReport
{
	uint assets;
	// Meshes given back *without* their file going with them — the per-mesh half
	// of the sweep, which is what G3/S3's refcount-per-mesh bought. A file whose
	// every mesh went is counted in `assets` instead, not twice.
	uint meshes;
	uint textures;
	usz bytes;
}

<*
 An asset's node tree, flattened into creation order: one entry per node that
 should exist, each naming its parent by position in the same list.

 **Where the "what does a glTF node become" policy lives, once.** Two things
 build a scene out of an asset — `Scene.instantiate` on the host and
 `asset.instantiate()` in JavaScript, which builds `Object3D`s and lets the
 normal `add` path materialize them — and the two producing different trees for
 one file would be a bug nobody would look for. So neither of them decides
 anything: `Assets.flatten` decides, and they both walk its answer.

 Parents always precede their children, because the walk is depth-first from the
 roots. That is what lets a consumer create nodes in one pass with no fixups.
*>
struct PlacedNode
{
	// Borrowed from the asset, valid until the asset is unloaded. Copy it if it
	// needs to outlive the walk.
	String name;

	// Index into the flattened list, or -1 for a root.
	int parent;
	// Index into `Asset.meshes`, or -1 for a group.
	int mesh;
	// The glTF node this came from, or -1 for an entry the walk *synthesized* —
	// the per-primitive children of a node whose mesh has several. An animation
	// channel targets a glTF node index, so this is what lets `Scene.instantiate`
	// build the map a player needs, and the -1s are exactly the nodes no channel
	// can name.
	int gltf_node;

	Vec3 position;
	Quaternionf rotation;
	Vec3 scale;

	// Straight into `Node.color`. `NO_TINT` for every entry that came from a
	// plain glTF node — only `EXT_mesh_gpu_instancing`'s `_COLOR_0` puts anything
	// else here, which is how a per-copy colour survives a round trip without
	// becoming a material per copy.
	float[4] color;
}

<*
 Every loaded asset, and everything shared between them.

 A `GpuMesh*` or `Asset*` handed out from here is valid only until the next
 `load` — the pools are `List`s and growing one moves its contents.

 ## Slots are reused, which is why handles carry a generation

 Both pools keep a free list and hand dead slots back out, so a game that cycles
 through a hundred levels holds as many slots as its largest level rather than as
 many as it ever loaded. For assets that reuse is visible to JavaScript, so an
 `AssetId` carries a generation and a stale one is refused. For textures it is
 not: the only thing that can name a texture is a `GpuMesh`, a `GpuMesh` holds a
 reference for as long as it exists, and a slot is therefore only ever freed when
 nothing at all points at it. A generation there would be a field nothing could
 ever observe.
*>
struct Assets
{
	List{Asset} assets;
	List{uint} free_slots;

	// Shared across every asset. Since M5 there is nothing parallel to this:
	// the image and its sampler are pushed straight into the command buffer at
	// draw time, so a texture is a texture and not also a descriptor set.
	List{SharedTexture} textures;
	List{uint} free_textures;

	Texture white;
	bool has_white;

	// How many times encoded image bytes have been handed to the decoder, over
	// the life of this table. Kept because `ImageMemo` is otherwise invisible:
	// texture counts, draw calls and pixels are all identical with the memo and
	// without it, so a test asserting on any of those passes just as happily
	// when the memo is deleted. This is the one number that moves.
	uint decodes;

	// The device, for the one path that cannot be handed one: `Assets.retain` is
	// called from `Scene.create_slot`, which has no `Gpu*` and should not grow
	// one — a scene is not a renderer — and since G3/S3 retaining a mesh is what
	// uploads it.
	//
	// **Only the lazy-upload path reads this.** Every other method still takes
	// the device as a parameter, which is what keeps "who owns the device" a
	// question with one answer. Null in a scene-math runtime, where there is
	// nothing to upload to and `ensure_uploaded` therefore does nothing.
	Gpu* gpu;

	// Set once an image the decoder does not handle has been reported, so a
	// file with ninety KTX2 textures says so once rather than ninety times.
	bool warned_unsupported_image;
	// The same, for a primitive whose upload failed.
	bool warned_upload_failed;
	bool started;
}

<*
 Give every list the heap before anything is pushed into it.

 A List left zero-initialised has a null allocator, and `list_ensure_capacity`
 resolves null to `tmem`: the first push would back the list with temp-arena
 memory, and any `@pool()` open up the stack would free it on the way out.
 Nothing faults there — the entries turn into garbage and the crash lands
 wherever the list is next walked, which for an asset is at draw time or at
 teardown, a long way from the cause. vulkan.c3l's MemoryAllocator carries the
 same note for the same reason.
*>
fn Assets* Assets.init(&self, Gpu* gpu = null)
{
	self.gpu = gpu;
	self.assets.init(mem, 4);
	self.free_slots.init(mem, 4);
	self.textures.init(mem, 8);
	self.free_textures.init(mem, 4);
	self.started = true;
	return self;
}

<*
 The asset a handle names, or null if it names none.

 Three ways to get null and they are deliberately one answer: out of range, a
 slot nothing occupies, and a slot occupied by a *later* asset than the one the
 handle was taken from. All three mean "this handle is not a loaded asset", and
 every caller does the same thing about it.
*>
fn Asset* Assets.slot(&self, AssetId id)
{
	if (id.index >= self.assets.len()) return null;
	Asset* asset = &self.assets[id.index];
	if (!asset.alive || asset.generation != id.generation) return null;
	return asset;
}

<*
 A mesh by asset and index, or null.

 Bounds-checked rather than asserted because the handles reaching here come out
 of `Scene`, and a node holding a stale asset handle should draw nothing rather
 than read a freed list.
*>
fn GpuMesh* Assets.mesh(&self, AssetId asset, uint mesh)
{
	Asset* owner = self.slot(asset);
	if (owner == null) return null;
	if (mesh >= owner.meshes.len()) return null;
	return &owner.meshes[mesh];
}

<*
 Find a mesh inside an asset by its glTF name — `kit.mesh("wall_corner_02")`.

 A glTF mesh with several primitives produced several `GpuMesh` entries sharing
 one name; this returns the first, which is the one a caller naming a mesh means.

 @return `An index into the asset's meshes, or -1.`
*>
fn int Assets.find_mesh(&self, AssetId asset, String name)
{
	Asset* owner = self.slot(asset);
	if (owner == null) return -1;
	foreach (i, &mesh : owner.meshes)
	{
		if (mesh.name == name) return (int)i;
	}
	return -1;
}

<*
 One more live node draws this mesh — and, since G3/S3, the moment the mesh is
 put on the device.

 **Retaining is what uploads.** `Assets.load` describes a file and stops, so a
 mesh slot has a name, a vertex count and bounds and nothing else until something
 starts drawing it. `Scene.create_slot` is the one place a node can begin naming
 a mesh, it calls this, and this is therefore the one place "first use" is
 defined. The symmetry with `release` is the point: uploaded when something
 begins drawing it, freed when nothing does.

 The count is per mesh and `Asset.refs` is their sum, kept here so that
 `unload_unused`'s "is this whole file unused" test stays one comparison.

 @param mesh : `An index into the asset's meshes, or NO_MESH for a group — which retains nothing, because a group draws nothing.`
*>
fn void Assets.retain(&self, AssetId asset, uint mesh)
{
	Asset* owner = self.slot(asset);
	if (owner == null || mesh >= owner.meshes.len()) return;

	owner.meshes[mesh].refs++;
	owner.refs++;
	self.ensure_uploaded(asset, mesh);
}

<*
 One fewer. The mesh's buffers are not freed here — `unload_unused` is the only
 thing that frees, for G2/S3's reason: a collector-driven free would make the
 resident number depend on when nodes happened to die, and a level boundary is
 an explicit moment.
*>
fn void Assets.release(&self, AssetId asset, uint mesh)
{
	Asset* owner = self.slot(asset);
	if (owner == null || mesh >= owner.meshes.len()) return;

	if (owner.meshes[mesh].refs > 0) owner.meshes[mesh].refs--;
	if (owner.refs > 0) owner.refs--;
}

<*
 How many assets are resident — what `stats()` reports and what a load-unload
 cycle has to return to.

 Counted rather than stored, because `assets.len()` is the number of *slots* the
 table has ever needed and this is the number a game watches. They differ by
 exactly the free list, and conflating them would make a working unload look
 like a leak.
*>
fn uint Assets.resident(&self)
{
	uint live = 0;
	foreach (&asset : self.assets)
	{
		if (asset.alive) live++;
	}
	return live;
}

<*
 How many unique textures are resident. `resident`'s argument, one level down.
*>
fn uint Assets.texture_count(&self)
{
	uint live = 0;
	foreach (&shared : self.textures)
	{
		if (shared.alive) live++;
	}
	return live;
}

<*
 What every unique texture costs on the device, as `stats()` reports it.

 Counted off the deduplicated list, so two kit pieces sharing an image are
 counted once — which is the number worth showing an agent, because it is the
 one that changes when the sharing breaks.

 **The mip chain is counted too**, by summing the levels rather than by
 multiplying the top one by four thirds. The closed form is only right for a
 square power of two: a 1024x16 has eleven levels of which seven are 16 pixels
 tall or less, and the ratio is nothing like 1.33. Reporting a texture budget a
 third smaller than it is would be the kind of wrong that only shows up as an
 out-of-memory on someone else's device.
*>
fn usz Assets.texture_bytes(&self)
{
	usz total = 0;
	foreach (&shared : self.textures)
	{
		if (!shared.alive) continue;
		uint width = shared.texture.width;
		uint height = shared.texture.height;
		for (uint level = 0; level < shared.texture.levels; level++)
		{
			total += (usz)width * height * 4;
			if (width > 1) width /= 2;
			if (height > 1) height /= 2;
		}
	}
	return total;
}

<*
 The texture a mesh draws with: its own, or the white stand-in.

 Answers with the `Texture` rather than a descriptor set because there are no
 descriptor sets any more — `MeshPass.record` pushes the image and sampler into
 the command buffer directly. The white fallback is unchanged and still does the
 same job: the binding is always occupied, so a textured mesh and an untextured
 one are the same pipeline and there is no shader permutation to manage.
*>
fn Texture* Assets.texture_for(&self, GpuMesh* mesh) => self.texture_at(mesh.texture);

<*
 A texture by index, or the white stand-in when there is not one.

 `texture_for`'s body, lifted out when a *material* became able to name a
 texture as well as a mesh. Both callers want the same two things — the image,
 and something valid when there is no image — so this is one function rather
 than a mesh-shaped one and a material-shaped one that would drift.

 An out-of-range index and a dead slot both answer white. From a live mesh
 neither is reachable, because a texture is only freed when nothing names it, so
 that is the backstop for a bug in the refcount rather than a case anything
 relies on. White is what it degrades to: a visibly wrong colour, rather than a
 sampled freed image, which is a picture that is right until it is not.
*>
fn Texture* Assets.texture_at(&self, int index)
{
	if (index < 0 || index >= self.textures.len()) return &self.white;
	SharedTexture* shared = &self.textures[index];
	if (!shared.alive) return &self.white;
	return &shared.texture;
}

<*
 Whether an index names a texture that is actually there.

 Separate from `texture_at` because the two questions want different answers to
 the same input: drawing wants a picture and will take white, while *accepting*
 an index from a script wants to refuse it — a material silently bound to white
 is a texture that did not load and did not say so.
*>
fn bool Assets.texture_alive(&self, int index)
{
	if (index < 0 || index >= self.textures.len()) return false;
	return self.textures[index].alive;
}

<*
 How many things name this texture. Zero for an index that names nothing.

 Exposed because the callers that *release* a texture need to know whether their
 release is the last one: freeing an image the GPU may still be sampling is the
 hazard `unload_unused` waits for the device over, and waiting on every release
 instead would put a device stall inside an ordinary `material.map = ...`.
*>
fn uint Assets.texture_refs(&self, int index)
{
	if (!self.texture_alive(index)) return 0;
	return self.textures[index].refs;
}

// ============================================================================
// Slots
// ============================================================================

<*
 File a finished asset in the table and answer with a handle to it.

 Reuses a freed slot when there is one, exactly as `Scene.create_slot` does. The
 generation it hands back is the one the slot already carried — `free_slot`
 climbed it on the way out — so a handle to the new occupant can never compare
 equal to a handle to the old one.

 @param asset : `Fully built. Ownership of its path and its meshes passes to the table.`
*>
fn AssetId Assets.claim_slot(&self, Asset asset)
{
	uint index;
	if (self.free_slots.len() > 0)
	{
		index = self.free_slots.pop()!!;
		// The generation is the slot's, not the incoming asset's: it is the one
		// piece of a dead slot that has to survive being overwritten.
		uint generation = self.assets[index].generation;
		self.assets[index] = asset;
		self.assets[index].generation = generation;
	}
	else
	{
		index = (uint)self.assets.len();
		self.assets.push(asset);
	}

	Asset* filed = &self.assets[index];
	filed.alive = true;
	filed.refs = 0;
	return { .index = index, .generation = filed.generation };
}

<*
 Give a slot's memory back, host and device, and mark every handle to it stale.

 Called only from `unload_unused`, and only for a slot at zero references — the
 caller owns that decision, because "is anything still using this" is a question
 about the scene and not about the asset table.

 **The device must already be idle.** A buffer freed while a frame in flight is
 still reading it is a use-after-free the validation layer reports two frames
 later, somewhere else. `unload_unused` waits once for the whole sweep rather
 than making this function wait per asset.
*>
fn void Assets.free_slot(&self, Gpu* gpu, uint index)
{
	if (index >= self.assets.len()) return;
	Asset* asset = &self.assets[index];
	if (!asset.alive) return;

	foreach (&mesh : asset.meshes)
	{
		// Before the buffers, because after `free_buffers` the mesh no longer
		// says which texture it was holding. The layer stack holds references of
		// its own and goes the same way, for the same reason.
		self.release_texture(gpu, mesh.texture);
		mesh.release_layers(self, gpu);
		mesh.free_buffers();
	}
	asset.meshes.free();
	free_nodes(asset);
	free_stream(asset);
	// Zeroed rather than left dangling: `claim_slot` overwrites the whole struct
	// and `Assets.free` walks every slot, so a freed `List` must not look
	// initialised to either of them.
	asset.meshes = {};
	if (asset.path.len > 0) asset.path.free(mem);
	asset.path = "";
	asset.bounds = {};
	asset.refs = 0;
	asset.alive = false;
	// The climb is what makes every outstanding `AssetId` to this slot stale.
	asset.generation++;
	self.free_slots.push(index);
}

<*
 Walk an asset's node tree into `out` in creation order.

 ## What a glTF node becomes

 One entry, carrying the node's TRS, always. If it draws exactly one primitive it
 draws it itself; if it draws several — a glTF mesh is a *list* of primitives —
 it becomes a group with one entry per primitive under it, which is what
 Three.js's `GLTFLoader` does for the same reason. If it draws none it is a
 group, which is what it already was.

 The single-primitive case is almost every node in almost every file, and a
 group wrapping one mesh would double the node count of a kit for nothing.

 ## An asset with no tree

 Generated primitives, convex hulls, and any glTF that declares meshes without
 nodes have no hierarchy. They flatten to one entry per mesh, all roots — which
 is what `MeshPass.place` did for every asset before G3, and is the right answer
 when there is no transform to honour.

 `out` is appended to and is not cleared.
*>
fn void Assets.flatten(&self, AssetId asset, List{PlacedNode}* out)
{
	Asset* loaded = self.slot(asset);
	if (loaded == null) return;

	if (loaded.nodes.len() == 0)
	{
		foreach (i, &mesh : loaded.meshes)
		{
			out.push({
				.name = mesh.name,
				.parent = -1,
				.mesh = (int)i,
				.gltf_node = -1,
				.position = { 0, 0, 0 },
				.rotation = NO_ROTATION,
				.scale = { 1, 1, 1 },
				.color = NO_TINT,
			});
		}
		return;
	}

	foreach (root : loaded.roots)
	{
		self.flatten_node(asset, root, -1, out);
	}
}

<*
 One asset node and everything under it.

 Recursive rather than iterative because a glTF hierarchy is a prop's rig, not a
 data structure with an adversary — the depth is single digits in every file that
 exists. A cycle would not terminate; a cycle is also not expressible, because
 `record_nodes` derives roots from "nothing claims it" and a cycle claims all of
 its own members, so a cyclic subtree has no root and is never reached.
*>
fn void Assets.flatten_node(&self, AssetId asset, uint index, int parent, List{PlacedNode}* out)
{
	Asset* loaded = self.slot(asset);
	if (loaded == null || index >= loaded.nodes.len()) return;
	AssetNode* source = &loaded.nodes[index];

	// An instanced node is a group over its copies, for the same reason a node
	// whose glTF mesh has several primitives is: the transform being placed is
	// not the node's own. The copies are children of it, so the node's own TRS
	// still applies to all of them and each copy's is relative to that — which is
	// what the extension says instance transforms are.
	bool instanced = source.instances.len() > 0 && source.mesh_count > 0;
	bool draws_itself = source.mesh_count == 1 && !instanced;
	int here = (int)out.len();

	out.push({
		.name = source.name,
		.parent = parent,
		.mesh = draws_itself ? (int)source.first_mesh : -1,
		.gltf_node = (int)index,
		.position = source.position,
		.rotation = source.rotation,
		.scale = source.scale,
		.color = NO_TINT,
	});

	if (instanced)
	{
		// Every primitive of the mesh, once per copy. A glTF mesh of two
		// primitives instanced a hundred times is two hundred entries and two
		// `GpuMesh`es, which is two draw calls of a hundred — the same answer the
		// renderer would have reached from a hundred hand-written nodes.
		foreach (&copy : source.instances)
		{
			for (uint i = 0; i < source.mesh_count; i++)
			{
				out.push({
					.name = loaded.meshes[(sz)(source.first_mesh + i)].name,
					.parent = here,
					.mesh = (int)(source.first_mesh + i),
					.gltf_node = -1,
					.position = copy.position,
					.rotation = copy.rotation,
					.scale = copy.scale,
					.color = copy.color,
				});
			}
		}
	}
	else if (!draws_itself)
	{
		for (uint i = 0; i < source.mesh_count; i++)
		{
			out.push({
				.name = loaded.meshes[(sz)(source.first_mesh + i)].name,
				.parent = here,
				.mesh = (int)(source.first_mesh + i),
				.gltf_node = -1,
				.position = { 0, 0, 0 },
				.rotation = NO_ROTATION,
				.scale = { 1, 1, 1 },
				.color = NO_TINT,
			});
		}
	}

	// Re-read: `out.push` cannot move the asset pool, but the recursion below
	// takes `&self`, and a pointer held across one is the habit worth not having.
	sz children = self.slot(asset).nodes[index].children.len();
	for (sz i = 0; i < children; i++)
	{
		self.flatten_node(asset, self.slot(asset).nodes[index].children[i], here, out);
	}
}

<*
 One more `GpuMesh` names this texture.

 Called at upload, once per mesh that resolves to the image — including the
 second and third primitive of a file that all share one material, because each
 of them will release it separately.
*>
fn void Assets.retain_texture(&self, int index)
{
	if (index < 0 || index >= self.textures.len()) return;
	// **A dead slot is refused, not counted.** An index can outlive the image it
	// named — `release_texture` frees the slot and `free_textures` hands it to the
	// next upload — and a retain on one of those would put a live count on an
	// entry holding a destroyed `VkImage`. Nothing would notice until the slot was
	// reused, at which point the new occupant would start life one reference too
	// high and never be freed. `release_texture` makes the same check on the way
	// out; this is the half that was missing.
	if (!self.textures[index].alive) return;
	self.textures[index].refs++;
}

<*
 One fewer, and the image goes when the last one does.

 The device must already be idle — see `free_slot`.
*>
fn void Assets.release_texture(&self, Gpu* gpu, int index)
{
	if (index < 0 || index >= self.textures.len()) return;
	SharedTexture* shared = &self.textures[index];
	if (!shared.alive || shared.refs == 0) return;

	shared.refs--;
	if (shared.refs > 0) return;

	// `Texture.free` zeroes the struct on its way out, which is what leaves a
	// dead slot inspectable: an image handle still sitting here would mean the
	// destroy did not happen, and a test can say so. Deliberately not zeroed
	// here as well — doing that would hide the one bug worth catching.
	if (gpu != null) shared.texture.free(gpu);
	shared.alive = false;
	self.free_textures.push((uint)index);
}

<*
 Free every asset nothing points at, and every texture that goes with them.

 `game.md` G2/S3: **not a finalizer.** A collector-driven free would make the
 resident number depend on when the interpreter felt like collecting, which is
 nondeterminism in the one number a game watches. A level boundary is an explicit
 moment; this is what happens at it.

 One pass, not a fixed point. An asset's references come from scene nodes and
 nothing else — no asset holds another — so there is nothing for a second pass to
 discover.

 @param gpu : `Null only in a scene-math runtime, which has nothing on a device to free.`
 @return `What went, for stats() and for whoever asked.`
*>
fn UnloadReport Assets.unload_unused(&self, Gpu* gpu)
{
	UnloadReport report;

	bool sweepable = false;
	foreach (&asset : self.assets)
	{
		if (!asset.alive) continue;
		if (asset.refs == 0)
		{
			sweepable = true;
			break;
		}
		// A file still in use can hold meshes that are not. Since G3/S3 the
		// refcount is per mesh, so a level that swapped which pieces of a kit it
		// places gives back the ones it stopped using without giving back the
		// kit — which is the whole reason the count moved down a level.
		foreach (&mesh : asset.meshes)
		{
			if (mesh.uploaded && mesh.refs == 0) { sweepable = true; break; }
		}
		if (sweepable) break;
	}
	if (!sweepable) return report;

	// `game.md` G2/S4, the simple half. `MAX_FRAMES_IN_FLIGHT` is 2 and a buffer
	// freed now may still be referenced by a command buffer the GPU has not
	// finished, so something has to keep the two apart. A tagged deletion queue
	// is the version that lets a game unload mid-frame without a hitch; a level
	// boundary is already a stall, so a full idle costs a frame or two exactly
	// where nobody is looking, and it is a fraction of the code. The queue is
	// what the first mid-gameplay unload should build.
	if (gpu != null) gpu.wait_idle();

	usz bytes_before = self.texture_bytes();
	uint textures_before = self.texture_count();

	foreach (i, &asset : self.assets)
	{
		if (!asset.alive) continue;
		if (asset.refs == 0)
		{
			self.free_slot(gpu, (uint)i);
			report.assets++;
			continue;
		}

		// The file stays; the pieces of it nothing draws do not. A freed mesh
		// keeps its slot, its name, its bounds and its glTF indices — everything
		// `describe_primitive` produced — so it is back to being described and
		// the next node that names it uploads it again.
		foreach (m, &mesh : asset.meshes)
		{
			if (!mesh.uploaded || mesh.refs > 0) continue;
			self.release_texture(gpu, mesh.texture);
			// The stack is re-resolved when the mesh uploads again, exactly as the
			// base colour map is, so giving it back here is what keeps a sweep of an
			// unused piece of a kit from holding that piece's images forever.
			mesh.release_layers(self, gpu);
			mesh.release_device();
			mesh.uploaded = false;
			mesh.texture = -1;
			mesh.has_normals = false;
			mesh.has_uvs = false;
			mesh.index_count = 0;
			mesh.base_color = { 1, 1, 1, 1 };
			report.meshes++;
		}
	}

	report.textures = textures_before - self.texture_count();
	report.bytes = bytes_before - self.texture_bytes();
	return report;
}

// ============================================================================
// Loading
// ============================================================================

<*
 Load a `.glb` or `.gltf`, upload everything it needs to draw, and close the
 file.

 Loading the same path twice returns the first load. That is the coarse half of
 "linked, not duplicated" — the fine half is the content-hash texture dedup
 below, which catches two *different* files sharing an image.

 @param path : `A .glb or a .gltf; gltf.c3l reads both.`
 @return `The asset's handle, for Scene.add_mesh.`
 @return? ASSET_HAS_NO_MESHES : `The file parsed but contains no drawable geometry, which is almost always the wrong file rather than an empty one.`
*>
fn AssetId? Assets.load(&self, Gpu* gpu, String path)
{
	if (!self.started) self.init();

	foreach (i, &existing : self.assets)
	{
		// Dead slots keep their path until they are overwritten, so the liveness
		// test is what stops an unloaded file being handed back as loaded.
		if (existing.alive && existing.path == path)
		{
			return { .index = (uint)i, .generation = existing.generation };
		}
	}

	// Opened before anything is allocated, because a `defer catch` covers the
	// statements below it and not the one that registers it. A path copied
	// ahead of this line leaks on every path that does not open — which is the
	// common case for the bad-path branch, not a rare one.
	gltf::GltfStream stream = gltf::open(path)!;

	Asset asset = { .path = path.copy(mem), .stream = stream, .has_stream = true };
	// Everything below this point can fail, and the asset is not on
	// `self.assets` yet — so the file it opened is its own to close.
	defer catch
	{
		asset.stream.close();
		asset.meshes.free();
		asset.images.free();
		asset.path.free(mem);
	}

	// Both are mmap-and-slice for a `.glb`, which is the format that matters:
	// one buffer, mapped, with the OS paging in only what is touched. On a
	// `.gltf` with external files they are real reads, and `load_mesh_buffers`
	// and `load_material_images` are the verbs that would narrow them. Left
	// blunt because the cost this step exists to remove is three.c3's own —
	// the per-primitive walk, the upload and the BVH — not the file I/O.
	asset.stream.load_all_buffers()!;
	asset.stream.load_all_images()!;

	if (asset.stream.gltf.meshes.len() == 0) return ASSET_HAS_NO_MESHES~;

	asset.meshes.init(mem, 8);
	asset.images.init(mem, 4);

	bool first_bounds = true;

	// Where each glTF mesh's primitives landed in `asset.meshes`, so the node
	// pass below can turn a node's mesh index into a range. Built here rather
	// than recomputed because a primitive with no vertices is skipped, so the
	// mapping is not arithmetic.
	List{uint} mesh_first;
	List{uint} mesh_count;
	mesh_first.init(mem, 8);
	mesh_count.init(mem, 8);
	defer mesh_first.free();
	defer mesh_count.free();

	foreach (mesh_index, mesh : asset.stream.gltf.meshes)
	{
		uint first = (uint)asset.meshes.len();

		foreach (primitive_index, primitive : mesh.primitives)
		{
			GpuMesh described = describe_primitive(&asset.stream, mesh, primitive);
			if (described.vertex_count == 0) continue;
			described.gltf_mesh = (int)mesh_index;
			described.gltf_primitive = (int)primitive_index;

			if (first_bounds)
			{
				asset.bounds = described.bounds;
				first_bounds = false;
			}
			else
			{
				asset.bounds.expand_by_aabb(described.bounds);
			}
			asset.meshes.push(described);
		}

		mesh_first.push(first);
		mesh_count.push((uint)asset.meshes.len() - first);
	}

	if (asset.meshes.len() == 0) return ASSET_HAS_NO_MESHES~;

	record_nodes(&asset, &asset.stream, mesh_first.array_view(), mesh_count.array_view());
	record_clips(&asset);

	return self.claim_slot(asset);
}

<*
 One primitive as far as the JSON describes it: a name, a vertex count, and
 bounds. Nothing on the device.

 **This is `Assets.load`'s whole job since G3/S3.** A 200-mesh kit costs 200 of
 these — three accessor lookups each — instead of 200 stream walks, 600 buffer
 uploads and 200 BVH builds, and a level that places twelve pays for twelve.

 All three fields come out of the JSON because the glTF spec puts them there: a
 POSITION accessor carries its `count`, and its `min`/`max` are *required*, which
 is the same reading `inventory.c3` relies on and the reason bounds are free
 before anything is loaded. `Asset.bounds` is therefore correct on a file that
 has never uploaded a byte — which `camera.frameAll()` depends on.

 A vertex count of zero is the caller's signal to skip the slot entirely: it
 means the primitive names no POSITION accessor, which is a primitive that could
 never draw.
*>
fn GpuMesh describe_primitive(gltf::GltfStream* stream, gltf::Mesh mesh, gltf::Primitive primitive) @local
{
	GpuMesh out = {
		.texture = -1,
		.base_color = { 1, 1, 1, 1 },
		.gltf_mesh = -1,
		.gltf_primitive = -1,
	};

	sz? position_accessor = primitive.attributes.get("POSITION");
	if (catch position_accessor) return out;
	if (position_accessor < 0 || position_accessor >= stream.gltf.accessors.len()) return out;

	out.name = mesh.name.copy(mem);
	out.vertex_count = stream.gltf.accessors[position_accessor].count;

	gltf::Aabb box = stream.gltf.primitive_aabb(primitive);
	out.bounds = { .min = box.min, .max = box.max };

	return out;
}

<*
 Put a described mesh on the device, if it is not there already.

 The moment "first use" means, and the only place a lazily loaded mesh becomes a
 drawable one. Called from `Assets.retain` — so **the trigger is a node starting
 to draw the mesh**, not a script naming it. That is one choke point rather than
 one per JavaScript verb, and it is exactly symmetric with `release`: a mesh is
 uploaded when something begins drawing it and freed when nothing does.

 A failure is reported once and then swallowed. The alternative is that one
 unreadable primitive in a ninety-mesh kit fails the `add` that happened to touch
 it, which is a failure in a place that has nothing to do with the cause; a mesh
 that did not upload draws nothing and picks nothing, which is what a material
 whose texture would not decode already does.

 @param mesh : `An index into the asset's meshes. Out of range is a no-op.`
*>
fn void Assets.ensure_uploaded(&self, AssetId asset, uint mesh)
{
	if (self.gpu == null) return;

	Asset* owner = self.slot(asset);
	if (owner == null || mesh >= owner.meshes.len()) return;
	if (owner.meshes[mesh].uploaded) return;
	// A generated shape was uploaded when it was built and has no file to go
	// back to; reaching here for one would mean its `uploaded` flag was lost.
	if (!owner.has_stream) return;

	int gltf_mesh = owner.meshes[mesh].gltf_mesh;
	int gltf_primitive = owner.meshes[mesh].gltf_primitive;
	if (gltf_mesh < 0 || gltf_mesh >= owner.stream.gltf.meshes.len()) return;

	gltf::Mesh source = owner.stream.gltf.meshes[gltf_mesh];
	if (gltf_primitive < 0 || gltf_primitive >= source.primitives.len()) return;

	if (catch self.ensure_white(self.gpu)) return;

	GpuMesh? built = self.upload_primitive(
		self.gpu, &self.slot(asset).stream, &self.slot(asset).images,
		source, source.primitives[gltf_primitive]
	);
	if (catch err = built)
	{
		if (!self.warned_upload_failed)
		{
			io::printfn("three: a mesh could not be uploaded (%s); it will draw nothing", err);
			self.warned_upload_failed = true;
		}
		return;
	}

	// Re-read: `upload_primitive` takes `&self` and may have grown the texture
	// table, and the asset pool is a `List` like any other.
	Asset* filed = self.slot(asset);
	if (filed == null) return;

	// The described slot already holds the name, the bounds and the count, and
	// `describe_primitive` and `upload_primitive` agree on all three. Keeping
	// the described name is what makes the two paths not need to: the name is
	// allocated once, at describe time, and freeing the uploaded copy here means
	// there is still exactly one.
	GpuMesh fresh = built;
	if (fresh.name.len > 0) fresh.name.free(mem);
	fresh.name = filed.meshes[mesh].name;
	fresh.refs = filed.meshes[mesh].refs;
	fresh.gltf_mesh = gltf_mesh;
	fresh.gltf_primitive = gltf_primitive;
	fresh.uploaded = true;

	filed.meshes[mesh] = fresh;
}


<*
 Copy the glTF node hierarchy onto the asset.

 Separate from the upload loop because it touches nothing on the device and
 nothing can fail in it — a file with a broken node index gets a group where it
 asked for geometry, which is visibly wrong in the right place rather than a
 failed load.

 **Roots are computed rather than read from `scenes`.** A glTF names its roots in
 `scenes[n].nodes`, but `scenes` is optional, a file may declare several, and
 gltf.c3l does not parse the default-scene index. "Nothing lists it as a child"
 answers the question for every one of those cases with one pass, and is the same
 answer for a well-formed file.
*>
fn void record_nodes(Asset* asset, gltf::GltfStream* stream, uint[] mesh_first, uint[] mesh_count) @local
{
	sz count = stream.gltf.nodes.len();
	if (count == 0) return;

	asset.nodes.init(mem, count);
	asset.roots.init(mem, 4);

	bool[] claimed = mem::new_array(bool, (usz)count);
	defer free(claimed);

	foreach (&source : stream.gltf.nodes)
	{
		AssetNode node = { .scale = { 1, 1, 1 }, .rotation = NO_ROTATION };
		if (source.name.len > 0) node.name = source.name.copy(mem);

		decompose(source.local_matrix(), &node.position, &node.rotation, &node.scale);

		if (source.mesh >= 0 && source.mesh < mesh_first.len)
		{
			node.first_mesh = mesh_first[source.mesh];
			node.mesh_count = mesh_count[source.mesh];
		}

		read_instances(&node, stream, source);

		node.children.init(mem, source.children.len());
		foreach (child : source.children)
		{
			if (child >= (uint)count) continue;
			node.children.push(child);
			claimed[child] = true;
		}

		asset.nodes.push(node);
	}

	foreach (i, taken : claimed)
	{
		if (!taken) asset.roots.push((uint)i);
	}
}

<*
 Read one node's `EXT_mesh_gpu_instancing` block into `AssetNode.instances`.

 gltf.c3l has already parsed the extension — `Node.attributes` is its attribute
 dictionary, accessor indices by name — so what is left is reading the accessors
 and filling in the identity for whichever of the four are absent. All four are
 optional: a batch that never rotates writes no `ROTATION`, and a batch of
 default-coloured copies writes no `_COLOR_0`.

 **The count comes from the accessors, and the shortest of them wins.** The
 extension has no length field: every attribute holds one entry per copy, so any
 of them answers for a well-formed file. Taking the shortest is what a
 malformed one gets, and it is the only answer that cannot read off the end of
 a buffer — a file whose `SCALE` is short would otherwise place its last copies
 from whatever follows it in the blob.

 Nothing here can fail loudly. `record_nodes` runs where a broken index gets a
 group instead of geometry, and this keeps that bargain: an unreadable
 instancing block leaves the node drawing once, in the right place, which is
 visibly less than the file promised rather than a crash.
*>
fn void read_instances(AssetNode* node, gltf::GltfStream* stream, gltf::Node* source) @local
{
	if (source.attributes.len() == 0) return;

	sz? translation = source.attributes.get("TRANSLATION");
	sz? rotation    = source.attributes.get("ROTATION");
	sz? scale       = source.attributes.get("SCALE");
	sz? tint        = source.attributes.get("_COLOR_0");

	sz count = -1;
	if (try translation) count = shortest(count, stream, translation);
	if (try rotation)    count = shortest(count, stream, rotation);
	if (try scale)       count = shortest(count, stream, scale);
	if (try tint)        count = shortest(count, stream, tint);
	if (count <= 0) return;

	node.instances.init(mem, count);
	for (sz i = 0; i < count; i++)
	{
		AssetInstance copy = {
			.position = { 0, 0, 0 },
			.rotation = NO_ROTATION,
			.scale = { 1, 1, 1 },
			.color = NO_TINT,
		};

		if (try translation) copy.position = stream.@cast_buffer(stream.gltf.accessors[translation], i, Vec3);
		if (try scale) copy.scale = stream.@cast_buffer(stream.gltf.accessors[scale], i, Vec3);
		if (try rotation)
		{
			Vec4 turned = stream.@cast_buffer(stream.gltf.accessors[rotation], i, Vec4);
			copy.rotation = { turned[0], turned[1], turned[2], turned[3] };
		}
		if (try tint)
		{
			Vec4 colored = stream.@cast_buffer(stream.gltf.accessors[tint], i, Vec4);
			copy.color = { colored[0], colored[1], colored[2], colored[3] };
		}

		node.instances.push(copy);
	}
}

// How many copies an attribute accounts for, against however few the ones
// already read did. `have` is -1 before anything has answered.
fn sz shortest(sz have, gltf::GltfStream* stream, sz accessor) @local
{
	if (accessor < 0 || accessor >= stream.gltf.accessors.len()) return have;
	sz count = (sz)stream.gltf.accessors[accessor].count;
	return have < 0 || count < have ? count : have;
}

<*
 Give back the node tree: every name, every child list, and the two lists
 themselves.

 One helper rather than inline in both places that free an asset. `free_slot`
 runs on a live slot being recycled and `Assets.free` runs at teardown, and a
 tree freed in one and not the other is a leak that only a hundred-cycle test
 finds.
*>
fn void free_nodes(Asset* asset) @local
{
	foreach (&node : asset.nodes)
	{
		if (node.name.len > 0) node.name.free(mem);
		node.children.free();
		node.instances.free();
	}
	asset.nodes.free();
	asset.roots.free();
	asset.nodes = {};
	asset.roots = {};
}

<*
 Name and measure the file's animation clips, without reading a keyframe.

 Everything here is in the JSON chunk. `gltf.c3l` parses the channels and
 samplers at `open`, and a clip's extent comes from the *time accessor's*
 `min`/`max` — required fields, the same ones `describe_primitive` reads bounds
 out of. So `mesh.animations` can answer with names and durations on a file that
 has uploaded nothing, which is what `three.inventory()` already promised one
 level up and what makes "does this character have a walk cycle" a free question.

 `Assets.ensure_clip` is what reads the curves, on the first `play`.
*>
fn void record_clips(Asset* asset) @local
{
	if (asset.stream.gltf.animations.len() == 0) return;
	asset.clips.init(mem, asset.stream.gltf.animations.len());

	foreach (i, &source : asset.stream.gltf.animations)
	{
		AnimationClip clip = {
			.start = source.min_time,
			.duration = source.duration(),
			.source = (uint)i,
		};
		// An unnamed clip is legal and useless to a script, so it gets the index
		// it would otherwise be addressed by anyway.
		clip.name = source.name.len > 0
			? source.name.copy(mem)
			: string::format(mem, "animation_%d", i);
		asset.clips.push(clip);
	}
}

<*
 Read one clip's curves off the still-open file.

 The lazy half, and the reason `Asset` holds its stream: a character with eleven
 clips reads the one that plays. Everything a channel needs is copied into
 three.c3's own arrays — see `AnimationChannel` for why not a view.

 Channels three.c3 cannot apply are dropped here rather than carried: `WEIGHTS`
 has no morph targets to drive and `POINTER` can address anything at all. A file
 with nothing but those produces a clip with no channels, which plays and does
 nothing, which is the honest outcome.

 Idempotent: `loaded` is set even for a clip that turned out to have no usable
 channels, so a `play` in an animation callback does not re-read the file every
 frame looking for curves that are not there.
*>
fn void Assets.ensure_clip(&self, AssetId asset, uint clip)
{
	Asset* owner = self.slot(asset);
	if (owner == null || clip >= owner.clips.len()) return;
	if (owner.clips[clip].loaded) return;
	owner.clips[clip].loaded = true;
	if (!owner.has_stream) return;

	uint source_index = owner.clips[clip].source;
	if (source_index >= owner.stream.gltf.animations.len()) return;

	// The buffers the samplers read from. For a `.glb` this is the same mmap
	// everything else uses; for a `.gltf` with an external `.bin` it is the verb
	// that reads only what this clip needs.
	if (catch owner.stream.load_animation_buffers(source_index)) return;

	owner.clips[clip].channels.init(mem, 8);

	gltf::Animation source = owner.stream.gltf.animations[source_index];
	foreach (&channel : source.channels)
	{
		AnimatedPath path;
		switch (channel.target.path)
		{
			case gltf::AnimationProperty.TRANSLATION: path = AnimatedPath.TRANSLATION;
			case gltf::AnimationProperty.ROTATION: path = AnimatedPath.ROTATION;
			case gltf::AnimationProperty.SCALE: path = AnimatedPath.SCALE;
			default: continue;
		}

		if (channel.sampler >= source.samplers.len()) continue;
		gltf::AnimationSampler sampler = source.samplers[channel.sampler];
		if (sampler.input >= owner.stream.gltf.accessors.len()) continue;
		if (sampler.output >= owner.stream.gltf.accessors.len()) continue;

		gltf::Accessor times = owner.stream.gltf.accessors[sampler.input];
		gltf::Accessor values = owner.stream.gltf.accessors[sampler.output];
		if (times.count == 0 || values.count == 0) continue;

		uint stride = path == AnimatedPath.ROTATION ? 4 : 3;
		// LINEAR and STEP store one value per key; CUBICSPLINE stores three.
		// A file whose counts disagree with its own interpolation is malformed,
		// and reading it would run off the end of the buffer.
		uint per_key = sampler.interpolation == gltf::Interpolation.CUBICSPLINE ? 3 : 1;
		if (values.count != times.count * per_key) continue;

		AnimationChannel built = {
			.node = channel.target.node,
			.path = path,
			.interp = sampler.interpolation,
			.stride = stride,
			.times = mem::new_array(float, times.count),
			.values = mem::new_array(float, (usz)values.count * stride),
		};

		for (sz k = 0; k < times.count; k++)
		{
			built.times[k] = owner.stream.@cast_buffer(times, k, float);
		}
		for (sz k = 0; k < values.count; k++)
		{
			// Read as a Vec4 regardless: a VEC3 accessor's stride is what
			// `@cast_buffer` uses to step, so this reads three floats and one
			// past them, and only `stride` of them are kept.
			Vec4 value = owner.stream.@cast_buffer(values, k, Vec4);
			for (uint c = 0; c < stride; c++) built.values[(usz)k * stride + c] = value[c];
		}

		owner.clips[clip].channels.push(built);
	}
}

<*
 Close the file an asset has been holding open since it was described, and give
 back the decode memo that went with it.

 The lifetime `game.md` G3/S3 calls the real work in the step. `Assets.load`
 parses the JSON and stops, so the document, its mmapped buffer and the memo have
 to survive until the last mesh in the file has been uploaded — which is a moment
 nobody can name in advance, so the answer is "until the asset goes".

 Idempotent, because `free_slot` runs on a recycled slot and `Assets.free` runs
 at teardown and an asset that has been through one must not have its file closed
 twice.
*>
fn void free_stream(Asset* asset) @local
{
	foreach (&clip : asset.clips) clip.free();
	asset.clips.free();
	asset.clips = {};

	if (asset.has_stream)
	{
		asset.stream.close();
		asset.has_stream = false;
	}
	asset.images.free();
	asset.images = {};
}

<*
 A transform matrix back into the translation, rotation and scale a node holds.

 Column lengths are the scale, the columns divided by them are the rotation
 basis, and the last column is the translation — which is exact for anything
 built as T·R·S, and every glTF node matrix is supposed to be.

 A negative determinant means the matrix mirrors, which no combination of
 positive scales can express. The sign goes onto X, which is what Three.js's
 `Matrix4.decompose` does; putting it anywhere is arbitrary and putting it
 nowhere renders the mesh inside out.

 Module-visible rather than file-local because `scene/export.c3` needs the same
 answer for the same reason: a flattened export writes world transforms, and a
 glTF node states a TRS triple.
*>
fn void decompose(Matrix4f m, Vec3* position, Quaternionf* rotation, Vec3* scale)
{
	*position = { m.m[12], m.m[13], m.m[14] };

	Vec3 axis_x = { m.m[0], m.m[1], m.m[2] };
	Vec3 axis_y = { m.m[4], m.m[5], m.m[6] };
	Vec3 axis_z = { m.m[8], m.m[9], m.m[10] };

	float sx = axis_x.length();
	float sy = axis_y.length();
	float sz_ = axis_z.length();

	Matrix3f linear = { .m = {
		m.m[0], m.m[1], m.m[2],
		m.m[4], m.m[5], m.m[6],
		m.m[8], m.m[9], m.m[10],
	} };
	if (linear.determinant() < 0) sx = -sx;

	*scale = { sx, sy, sz_ };

	// A zero-scaled axis has no direction to recover, and dividing by it would
	// put NaNs into the rotation — which propagate into the world matrix and
	// from there into every descendant. Identity is the honest answer: the node
	// is flat, and no rotation of nothing is distinguishable from another.
	if (math::abs(sx) < 1e-8f || math::abs(sy) < 1e-8f || math::abs(sz_) < 1e-8f)
	{
		*rotation = NO_ROTATION;
		return;
	}

	axis_x = axis_x * (1.0f / sx);
	axis_y = axis_y * (1.0f / sy);
	axis_z = axis_z * (1.0f / sz_);

	*rotation = quat_from_basis(axis_x, axis_y, axis_z);
}

<*
 An orthonormal basis as a quaternion, by Shepperd's method: pick the largest of
 the four possible denominators and divide by that one.

 The naive form takes `w = sqrt(1 + trace) / 2` and divides by it, which is
 fine until the trace approaches -1 — a rotation near 180° — where the
 denominator goes to zero and the result is noise. Choosing among the four
 keeps the divisor above 0.5 for every possible input.
*>
fn Quaternionf quat_from_basis(Vec3 x, Vec3 y, Vec3 z) @local
{
	float trace = x[0] + y[1] + z[2];

	if (trace > 0)
	{
		float root = math::sqrt(trace + 1.0f) * 2.0f;
		return { (y[2] - z[1]) / root, (z[0] - x[2]) / root, (x[1] - y[0]) / root, root * 0.25f };
	}
	if (x[0] > y[1] && x[0] > z[2])
	{
		float root = math::sqrt(1.0f + x[0] - y[1] - z[2]) * 2.0f;
		return { root * 0.25f, (y[0] + x[1]) / root, (z[0] + x[2]) / root, (y[2] - z[1]) / root };
	}
	if (y[1] > z[2])
	{
		float root = math::sqrt(1.0f + y[1] - x[0] - z[2]) * 2.0f;
		return { (y[0] + x[1]) / root, root * 0.25f, (z[1] + y[2]) / root, (z[0] - x[2]) / root };
	}
	float root = math::sqrt(1.0f + z[2] - x[0] - y[1]) * 2.0f;
	return { (z[0] + x[2]) / root, (z[1] + y[2]) / root, root * 0.25f, (x[1] - y[0]) / root };
}

<*
 Read one primitive's streams into tightly packed arrays and upload them.

 The `@each_*` macros are used rather than a memcpy of the accessor's range
 because a glTF buffer view may be strided — interleaved attributes are legal
 and common — and `@cast_buffer` is what knows the stride. What lands on the
 GPU is always tightly packed, which is what the shader's scalar-layout
 `float3*` reads expect.
*>
fn GpuMesh? Assets.upload_primitive(
	&self,
	Gpu* gpu,
	gltf::GltfStream* stream,
	List{ImageMemo}* images,
	gltf::Mesh mesh,
	gltf::Primitive primitive
)
{
	GpuMesh out = { .texture = -1, .base_color = { 1, 1, 1, 1 } };

	// A primitive that fails halfway has already put buffers on the device, and
	// nothing else knows about them yet — the mesh is only handed to `meshes`
	// on the way out. Without this the failure is a leak that surfaces as
	// "child objects not destroyed" when the device goes away, several layers
	// from the cause.
	defer catch out.free_buffers();

	// Heap-backed for the same reason as `Assets.init`, even though these are
	// freed in this scope: `@each_texcoord` formats an attribute name through
	// the temp arena, so this function already touches it.
	List{Vec3} positions;
	List{Vec3} normals;
	List{Vec2} uvs;
	List{uint} indices;
	positions.init(mem, 256);
	normals.init(mem, 256);
	uvs.init(mem, 256);
	indices.init(mem, 512);
	defer
	{
		positions.free();
		normals.free();
		uvs.free();
		indices.free();
	}

	stream.@each_position(primitive; Vec3 position, sz i) { positions.push(position); };
	if (positions.len() == 0) return out;

	stream.@each_normal(primitive; Vec3 normal, sz i) { normals.push(normal); };
	stream.@each_texcoord(primitive, 0; Vec2 uv, sz i) { uvs.push(uv); };

	read_indices(stream, primitive, &indices);
	// A primitive with no index accessor is a plain vertex list; give it the
	// trivial index buffer rather than carrying a second draw path for it.
	if (indices.len() == 0)
	{
		for (uint i = 0; i < positions.len(); i++) indices.push(i);
	}

	out.name = mesh.name.copy(mem);
	out.vertex_count = (uint)positions.len();
	out.index_count = (uint)indices.len();

	gltf::Aabb box = stream.gltf.primitive_aabb(primitive);
	out.bounds = { .min = box.min, .max = box.max };

	out.positions = gpu.upload_stream(positions.entries, Vec3::size * positions.len())!;
	out.indices = gpu.upload_indices(indices.entries, uint::size * indices.len())!;

	// A stream that is short is a stream that is absent: the shader indexes
	// every stream with the same SV_VertexID, so a normals array that does not
	// cover every vertex would read past its own buffer.
	out.has_normals = normals.len() == positions.len();
	if (out.has_normals) out.normals = gpu.upload_stream(normals.entries, Vec3::size * normals.len())!;

	out.has_uvs = uvs.len() == positions.len();
	if (out.has_uvs) out.uvs = gpu.upload_stream(uvs.entries, Vec2::size * uvs.len())!;

	out.build_bvh(positions.array_view(), indices.array_view());

	// The material, if the primitive names one.
	sz? material_index = primitive.attributes.get("material");
	if (try material_index)
	{
		if (material_index < stream.gltf.materials.len())
		{
			gltf::Material material = stream.gltf.materials[material_index];
			// Straight across, no transfer function: glTF defines
			// `baseColorFactor` linear and the shaders use `base_color` linear.
			// The one colour in this project that is *not* in a script's units.
			out.base_color = {
				material.baseColorFactor[0],
				material.baseColorFactor[1],
				material.baseColorFactor[2],
				material.baseColorFactor[3],
			};
			if (out.has_uvs)
			{
				out.texture = self.load_material_texture(gpu, stream, images, material.baseColorTexture)!;
				// **Gated on uvs for the same reason the base colour map is.** Every
				// image in a stack is sampled by uv, so a mesh without them would
				// hold references to pictures nothing can read.
				self.load_material_layers(gpu, stream, images, material, &out.layers)!;
			}
		}
	}

	return out;
}

<*
 Build the picking tree, and keep the geometry it points at.

 `collision::TriBVHNode` stores raw pointers to the vertex and triangle arrays
 rather than copying them, so these two allocations are part of the tree and are
 freed with it. That is the memory cost named in the header: roughly 24 bytes per
 vertex-and-triangle pair, resident for as long as the asset is loaded.

 A degenerate primitive — fewer than three indices — gets no tree rather than a
 tree of nothing, because `create_indexed_tri_bvh` requires a positive triangle
 count.
*>
fn void GpuMesh.build_bvh(&self, Vec3[] positions, uint[] indices)
{
	usz triangle_count = indices.len / 3;
	if (triangle_count == 0 || positions.len == 0) return;

	self.hull_positions = mem::new_array(Vec3, (sz)positions.len);
	self.hull_positions[..] = positions[..];

	self.hull_triangles = mem::new_array(collision::Triangle, (sz)triangle_count);
	for (usz i = 0; i < triangle_count; i++)
	{
		self.hull_triangles[i] = { indices[i * 3], indices[i * 3 + 1], indices[i * 3 + 2] };
	}

	self.bvh = collision::create_indexed_tri_bvh(self.hull_positions.ptr, self.hull_triangles.ptr, (sz)triangle_count);
}

<*
 Indices, read at whatever width the file stored them.

 glTF allows unsigned byte, short or int, and a chooser that assumes one width
 silently pairs adjacent bytes into one index — a 4-vertex quad comes back
 referring to vertex 770. Everything is widened to uint on the way to the GPU
 so there is a single index type to bind.
*>
fn void read_indices(gltf::GltfStream* stream, gltf::Primitive primitive, List{uint}* out)
{
	sz? attr = primitive.attributes.get("indices");
	if (catch attr) return;

	gltf::Accessor accessor = stream.gltf.accessors[attr];
	for (sz i = 0; i < accessor.count; i++)
	{
		switch (accessor.data_type)
		{
			case gltf::DataType.CHAR:
				out.push((uint)stream.@cast_buffer(accessor, i, char));
			case gltf::DataType.USHORT:
				out.push((uint)stream.@cast_buffer(accessor, i, ushort));
			case gltf::DataType.SHORT:
				out.push((uint)stream.@cast_buffer(accessor, i, short));
			default:
				out.push(stream.@cast_buffer(accessor, i, uint));
		}
	}
}

<*
 Resolve a material's base colour texture to a slot in `Assets.textures`.

 Two caches stand between a material and the decoder, in this order, and they
 answer different questions:

 - **The memo** (`ImageMemo`), keyed on this file's own image index. A material
   named by four primitives asks four times; the file's bytes are decoded once.
 - **The content hash**, keyed on the decoded pixels. Two *different* images,
   here or in a file loaded an hour ago, that hold the same picture.

 The order matters and only one way round is free: the memo costs a walk of a
 list one entry long per image in the file, and skips everything. The hash costs
 a decode, a `to_rgba` and a pass over the bytes before it can say anything at
 all — which is why it was doing all of that once per primitive until the memo
 went in front of it.

 ## It takes a `TextureInfo` rather than a `Material`

 It used to take the whole material and reach into `baseColorTexture` itself,
 which was exact while the base colour map was the only image this renderer read.
 A layer stack reads several — an albedo per layer, a packed mask, a normal map —
 and each of them is the same walk from a `textureInfo` to a slot, differing only
 in *which* info and in what colourspace it wants.

 So the info and the space are parameters. Passing the material and a "which
 field" selector was the other option and is the worse one: the selector would be
 a second vocabulary for something `TextureInfo` already names, and the caller
 that passed the wrong one would silently upload the wrong picture.

 @param info : `The glTF textureInfo to resolve. A source of -1 answers -1.`
 @param space : `SRGB for a colour map, LINEAR for one whose channels are numbers — a mask, a normal map.`
 @return `An index into Assets.textures, or -1 when there is no usable texture there.`
*>
fn int? Assets.load_material_texture(
	&self,
	Gpu* gpu,
	gltf::GltfStream* stream,
	List{ImageMemo}* images,
	gltf::TextureInfo info,
	ColorSpace space = ColorSpace.SRGB
)
{
	int texture_index = info.source;
	if (texture_index < 0) return -1;
	if (texture_index >= stream.gltf.textures.len()) return -1;

	int image_index = stream.gltf.textures[texture_index].source;
	if (image_index < 0 || image_index >= stream.gltf.images.len()) return -1;

	foreach (memo : *images)
	{
		if (memo.image != image_index || memo.space != space) continue;
		// The retain the decode path would have done, either by pushing a fresh
		// slot at one reference or by incrementing on a hash hit. Every
		// `GpuMesh` naming this texture has to count, or the first mesh to
		// unload takes the image out from under its neighbours.
		self.retain_texture(memo.texture);
		return memo.texture;
	}

	int resolved = self.decode_material_texture(gpu, stream, image_index, space)!;
	images.push({ .image = image_index, .space = space, .texture = resolved });
	return resolved;
}

<*
 Resolve a material's `CUSTOM_materials_layers` stack to texture slots.

 Does nothing at all — not even an allocation — for a material without the
 extension, which is every material in every file that was not authored for it.
 `gltf.c3l` has already parsed the JSON by the time this runs; what is left is the
 half it cannot do, which is turning texture indices into uploads.

 ## Which images get which colourspace, and why it is the whole point

 A base colour map is a picture somebody looked at, so it is `SRGB`. **A mask and a
 normal map are not pictures, they are numbers** — a weight and a direction — and
 loading either through an sRGB view puts every value through a transfer function
 it was never encoded with. `mapped_normal`'s header measures what that does to a
 normal map: the stored 0.5 meaning "no tilt" arrives as 0.21 and every surface
 leans the same way. A mask fares the same, and worse, because the result reads as
 the blend modes being wrong rather than as the image being misread.

 Getting this right is most of what this function is for. `ImageMemo` carrying the
 space is what makes it possible for one glTF image to be both.

 ## The PBR half is dropped here rather than stored

 `metallicFactor`, `roughnessFactor`, `metallicRoughnessTexture`, `subsurface`,
 `heightTexture` and `bump` are all parsed by `gltf.c3l` and none of them is copied
 out. `plan.md` §12: `lambert()` is the whole of the built-in light, so these are
 inputs to an equation nothing evaluates, and a field carried to the JS side would
 be an API surface that provably changes no pixel. The images they name are not
 uploaded either, which is the part that costs something — a file with a roughness
 map per layer pays nothing for it here.

 Fails with whatever an upload failed with. A material without the extension
 cannot fail, because it does nothing.
*>
fn void? Assets.load_material_layers(
	&self,
	Gpu* gpu,
	gltf::GltfStream* stream,
	List{ImageMemo}* images,
	gltf::Material material,
	GpuLayers* out
)
{
	if (!material.has_layers()) return;

	out.present = true;
	out.mask_texture = -1;
	out.layers.init(mem, material.layers_ext.layers.len());

	foreach (source : material.layers_ext.layers)
	{
		GpuLayer layer = {
			.base_color = {
				source.baseColorFactor.x,
				source.baseColorFactor.y,
				source.baseColorFactor.z,
				source.baseColorFactor.w,
			},
			.emissive_factor = { source.emissiveFactor.x, source.emissiveFactor.y, source.emissiveFactor.z },
			.texture = -1,
			.normal_texture = -1,
			.emissive_texture = -1,
			.mask_texture = -1,
			.blend_mode = (uint)source.blend_mode.ordinal,
			.mask_channel = (uint)source.mask.channel.ordinal,
			.mask_source = (uint)source.mask.source.ordinal,
			.opacity = source.opacity,
			.invert = source.mask.invert,
			.enabled = source.enabled,
		};
		if (source.name.len > 0) layer.name = source.name.copy(mem);

		// **A disabled layer resolves nothing.** It reaches the JS side as a
		// description with `enabled: false` on it, which the generator drops
		// before it emits a sampler for it — so uploading its images here would be
		// bytes on the device that no shader can name.
		if (source.enabled)
		{
			layer.texture = self.load_material_texture(gpu, stream, images, source.baseColorTexture)!;
			layer.normal_texture =
				self.load_material_texture(gpu, stream, images, source.normalTexture, ColorSpace.LINEAR)!;
			layer.emissive_texture = self.load_material_texture(gpu, stream, images, source.emissiveTexture)!;
			if (source.mask.source == gltf::LayerMaskSource.TEXTURE)
			{
				layer.mask_texture =
					self.load_material_texture(gpu, stream, images, source.mask.texture, ColorSpace.LINEAR)!;
			}
		}

		out.layers.push(layer);
	}

	self.hoist_shared_mask(gpu, out);
}

<*
 Move a mask every layer reads into the stack's own slot.

 **The extension has no "shared mask" object — the sharing is implicit**, and this
 is what makes it explicit. Each layer's mask names a `textureInfo` of its own, and
 a splat map authored the way the extension intends has all of them naming *one*
 RGBA image and differing only in `channel`. Left as it arrives, that is one
 sampler per layer holding the same picture: four bindings for a four-layer terrain
 where one would do, against a budget of eight (`MATERIAL_TEXTURE_LIMIT`). Hoisted,
 the generated shader samples it once into a `float4` and reads a component per
 layer — which is the arrangement the per-layer `channel` field exists for.

 The references move with it. Every masked layer resolved the slot and so took a
 reference; the first becomes the stack's and the rest are given back, so the count
 matches the one slot that now names it.

 **All or nothing.** A file whose layers name two different mask images keeps them
 per layer rather than getting a partial hoist, because the budget arithmetic is
 the same either way and "some layers share and some do not" is a shape no exporter
 produces — Blender's writes one image. If one ever does, the worst case is that it
 spends the bindings it would have spent anyway.
*>
fn void Assets.hoist_shared_mask(&self, Gpu* gpu, GpuLayers* out)
{
	int shared = -1;
	foreach (layer : out.layers)
	{
		if (layer.mask_texture < 0) continue;
		if (shared < 0)
		{
			shared = layer.mask_texture;
			continue;
		}
		if (layer.mask_texture != shared) return;
	}
	if (shared < 0) return;

	out.mask_texture = shared;
	bool kept = false;
	foreach (&layer : out.layers)
	{
		if (layer.mask_texture < 0) continue;
		// The first layer's reference is the one the stack keeps; every other is a
		// duplicate of it and is given back here. Releasing all of them and then
		// retaining once would be the same count and one more chance to get the
		// order wrong on a slot whose last reference had just gone.
		if (kept) self.release_texture(gpu, layer.mask_texture);
		kept = true;
		layer.mask_texture = -1;
	}
}

<*
 Free a layer stack's own memory: the layer names and the list holding them.

 **Host memory only, and split from `release_layers` for one reason** — the two
 jobs have different sets of callers. Every path that destroys a mesh has to free
 this, including `Assets.free` at teardown, which deliberately gives *no*
 references back because it destroys the whole texture table a few lines later.
 Only the paths that unload a mesh while the table lives have references to
 return.

 Folding the two together is what the first attempt did, and the leak it produced
 is instructive: `free_slot` and `unload_unused` both called it and both were
 right, `Assets.free` called neither, and every layer name in every fixture leaked
 at process teardown. `free_buffers` is where "this mesh's host memory goes away"
 already lives, so this belongs to it.

 Safe on a stack that was never present and on one already freed — which is what
 lets `release_layers` call it and `free_buffers` call it again after.
*>
fn void GpuMesh.free_layers(&self)
{
	if (!self.layers.present) return;
	foreach (layer : self.layers.layers)
	{
		if (layer.name.len > 0) layer.name.free(mem);
	}
	self.layers.layers.free();
	// Zeroed rather than left holding a freed list, so `present` is false and a
	// second call — which `free_buffers` makes on the `free_slot` path — does
	// nothing rather than freeing twice.
	self.layers = { };
}

<*
 Give back every texture slot a layer stack holds, then free the stack.

 Called beside the release of `GpuMesh.texture` at each of the two sites that
 unload a mesh *while the texture table is still live*, because the references
 were taken beside that one. A stack that was never present gives nothing back
 and is safe to call on, which is what lets both call sites be unconditional.
*>
fn void GpuMesh.release_layers(&self, Assets* assets, Gpu* gpu)
{
	if (!self.layers.present) return;

	assets.release_texture(gpu, self.layers.mask_texture);
	foreach (layer : self.layers.layers)
	{
		assets.release_texture(gpu, layer.texture);
		assets.release_texture(gpu, layer.normal_texture);
		assets.release_texture(gpu, layer.emissive_texture);
		assets.release_texture(gpu, layer.mask_texture);
	}
	self.free_layers();
}

<*
 The slow half: bytes to a decoded image to a texture slot, with the content
 hash deciding whether the upload is needed.

 The hash is over the decoded RGBA rather than the encoded file, so two images
 that differ only in how they were compressed still count as one. Dimensions are
 compared too — a hash match with different extents would be a collision, and
 sharing on one would corrupt both.

 Reached at most once per image per file **per colourspace** — see `ImageMemo`
 for why the space belongs in that sentence. Split out from the lookup above so
 that the memo has something whose cost is obvious to be standing in front of.

 @param space : `SRGB for a colour map, LINEAR for one whose channels are numbers.`
*>
fn int? Assets.decode_material_texture(
	&self, Gpu* gpu, gltf::GltfStream* stream, int image_index, ColorSpace space = ColorSpace.SRGB
)
{
	char[]? encoded = stream.get_image_data((uint)image_index);
	if (catch encoded) return -1;

	// A texture that will not decode costs that material its texture and
	// nothing else. Failing the whole load instead would mean one KTX2 image in
	// a ninety-mesh file renders nothing at all, which is strictly less useful
	// than the same file rendered with its base colour factors — and an agent
	// that can see the geometry can tell what it is looking at.
	gltf::ImageType mime = stream.gltf.images[image_index].mimeType;
	self.decodes++;
	image::Image? maybe  = decode_image(mime, encoded);
	if (catch maybe)
	{
		if (!self.warned_unsupported_image)
		{
			io::printfn("three: %s textures are not decoded; those materials render untextured", image_type_name(mime));
			self.warned_unsupported_image = true;
		}
		return -1;
	}
	image::Image decoded = maybe;
	defer decoded.free();

	// **16-bit is refused rather than narrowed.** `Image.to_rgba` says in its own
	// comment that it does not handle a 16-bit source, and what it does instead
	// is index as though the source were 8-bit — so a 16-bit PNG that reaches it
	// does not come out darker or flatter, it comes out of the wrong bytes.
	// Garbled pixels look like a decoder bug; a material with no texture looks
	// like what this is, which is a format that is not supported yet.
	if (decoded.bit_depth == 16)
	{
		if (!self.warned_unsupported_image)
		{
			io::printfn(
				"three: 16-bit %s textures are not decoded; those materials render untextured", image_type_name(mime)
			);
			self.warned_unsupported_image = true;
		}
		return -1;
	}

	return self.claim_texture(gpu, decoded, space);
}

<*
 A decoded image to a texture slot, deduplicated by content hash.

 The tail `decode_material_texture` used to own, lifted out when
 `load_texture_file` needed exactly the same thing. Sharing it is not tidiness:
 it is what makes `three.texture("brick.png")` and the identical image embedded
 in a `.glb` **one upload**, because they hash the same decoded bytes against
 the same table. Two implementations of this would have been two texture slots
 holding the same picture, which is the bug the hash exists to prevent.

 The new slot starts at one reference and it belongs to the caller.

 **The colourspace is part of a texture's identity, not a setting on it.** The
 same PNG asked for as `SRGB` and as `LINEAR` is two images in two formats, and
 sharing a slot between them would hand whichever caller came second the other
 one's format — silently, since the picture is right and only the decode is
 wrong. So it joins the hash and the extents in what has to match. A file used
 as a colour map in one material and as a height map in another costs two
 uploads, which is the honest price of it being two different things.

 @param decoded : `8-bit. A 16-bit source must be refused before here, since to_rgba cannot narrow one.`
 @param space : `SRGB for a colour map, LINEAR for one whose channels are numbers.`
 @param mips : `False for pixels meant to be indexed exactly rather than sampled at a distance.`
 @require decoded.bit_depth != 16
 @return `An index into Assets.textures.`
*>
fn int? Assets.claim_texture(
	&self, Gpu* gpu, image::Image decoded, ColorSpace space = ColorSpace.SRGB, bool mips = true
)
{
	char[] rgba = decoded.to_rgba();
	defer free(rgba);

	ulong hash = content_hash(rgba);
	// Asked once, before the loop, and compared as a number: a chain the caller
	// declined and one it asked for are different images too, and the difference
	// is invisible in every other field.
	uint levels = gpu.levels_for(decoded.width, decoded.height, space, mips);
	foreach (i, &existing : self.textures)
	{
		if (!existing.alive) continue;
		if (existing.texture.hash == hash
			&& existing.texture.width == decoded.width
			&& existing.texture.height == decoded.height
			&& existing.texture.space == space
			&& existing.texture.levels == levels)
		{
			existing.refs++;
			return (int)i;
		}
	}

	Texture uploaded = gpu.create_texture(rgba, decoded.width, decoded.height, space, mips)!;

	// A freed slot before a fresh one, for `Assets`'s reason: the table should
	// be as large as the largest level, not as large as every level added up.
	if (self.free_textures.len() > 0)
	{
		uint index = self.free_textures.pop()!!;
		self.textures[index] = { .texture = uploaded, .refs = 1, .alive = true };
		return (int)index;
	}

	self.textures.push({ .texture = uploaded, .refs = 1, .alive = true });
	return (int)self.textures.len() - 1;
}

<*
 PNG's eight-byte signature. Fixed, at offset zero, and the reason
 `decode_by_signature` needs no guessing.
*>
const char[8] PNG_SIGNATURE = { 0x89, 'P', 'N', 'G', '\r', '\n', 0x1a, '\n' };

<*
 What these bytes are, by their first few rather than by the name of the file.

 **A file named `.png` that holds a JPEG is a thing that happens** — an export
 step renamed it, or a browser download did — and dispatching on the extension
 would hand PNG bytes to the JPEG decoder, which reports a corrupt file. That
 message sends a person looking for a corruption that is not there. Reading the
 signature costs eight comparisons and is never wrong about it.

 The glTF path next door does not do this and should not: a `.glb` states its
 own mime type per image, which is a stronger claim than a file name and is
 already what `decode_image` switches on.

 @return? TEXTURE_FORMAT_UNKNOWN : `Neither a PNG nor a JPEG. Named rather than attempted.`
*>
fn image::Image? decode_by_signature(char[] encoded)
{
	if (encoded.len >= PNG_SIGNATURE.len)
	{
		bool matches = true;
		foreach (i, byte : PNG_SIGNATURE)
		{
			if (encoded[i] != byte) matches = false;
		}
		if (matches) return png::load_bytes(encoded);
	}

	// SOI followed by any marker. Two bytes would be enough to be unambiguous
	// here, but every real JPEG has a third and requiring it costs nothing.
	if (encoded.len >= 3 && encoded[0] == 0xff && encoded[1] == 0xd8 && encoded[2] == 0xff)
	{
		return jpeg::load_bytes(encoded);
	}

	return TEXTURE_FORMAT_UNKNOWN~;
}

<*
 A PNG or JPEG on disk to a texture slot — `three.texture(path)`'s half of it.

 Goes through `claim_texture`, so it shares the table, the content hash and the
 refcount with every texture a glTF brought in. The reference it starts at
 belongs to whoever called: for the JS path that is the `Texture` handle the
 script is holding, and it is released by `dispose()` and by nothing else.
 A material naming the texture takes a reference of its own.

 **`space` is what makes a normal or roughness map possible**, and it defaults to
 the wrong thing for one on purpose: a texture named by a path is overwhelmingly
 a picture, and `SRGB` is what every call meant before the argument existed. A
 map whose channels are numbers has to say so, and `ColorSpace` says what each
 mistake looks like on screen.

 @param space : `SRGB for a colour map, LINEAR for a normal, roughness, height or lookup map.`
 @param mips : `False for pixels meant to be indexed exactly. A full chain otherwise.`
 @return `An index into Assets.textures, at one reference.`
 @return? TEXTURE_UNREADABLE : `Nothing at that path, or it could not be read.`
 @return? TEXTURE_FORMAT_UNKNOWN : `Not a PNG or a JPEG, by its first bytes.`
 @return? TEXTURE_BIT_DEPTH : `A 16-bit PNG. It decodes; it cannot be narrowed to RGBA8 here.`
*>
fn int? Assets.load_texture_file(
	&self, Gpu* gpu, String path, ColorSpace space = ColorSpace.SRGB, bool mips = true
)
{
	if (!file::is_file(path)) return TEXTURE_UNREADABLE~;

	char[]? encoded = file::load(mem, path);
	if (catch encoded) return TEXTURE_UNREADABLE~;
	defer free(encoded);

	// Counted with the glTF decodes rather than separately: `decodes` answers
	// "how much decoding has this table paid for", and a script that reloads the
	// same PNG in a loop is exactly the case that number exists to expose.
	self.decodes++;
	image::Image decoded = decode_by_signature(encoded)!;
	defer decoded.free();

	if (decoded.bit_depth == 16) return TEXTURE_BIT_DEPTH~;
	return self.claim_texture(gpu, decoded, space, mips);
}

<*
 PNG and JPEG, which is what `image.c3l` decodes.

 KTX2 (KHR_texture_basisu) is the notable absence and it is common in shipped
 assets. Anything else is not an error the load should die on — see
 `load_material_texture`.
*>
fn image::Image? decode_image(gltf::ImageType mime, char[] encoded)
{
	switch (mime)
	{
		case gltf::ImageType.IMAGE_PNG:
			return png::load_bytes(encoded);
		case gltf::ImageType.IMAGE_JPEG:
			return jpeg::load_bytes(encoded);
		default:
			return UNSUPPORTED_IMAGE~;
	}
}

fn String image_type_name(gltf::ImageType mime)
{
	switch (mime)
	{
		case gltf::ImageType.IMAGE_PNG: return "PNG";
		case gltf::ImageType.IMAGE_JPEG: return "JPEG";
		case gltf::ImageType.IMAGE_BMP: return "BMP";
		case gltf::ImageType.IMAGE_GIF: return "GIF";
		case gltf::ImageType.IMAGE_KTX2: return "KTX2 (KHR_texture_basisu)";
		default: return "an unknown format";
	}
}

// ============================================================================
// Descriptors
// ============================================================================

<*
 The 1x1 white stand-in, created once for the whole table.

 It is what keeps this to a single pipeline: the sampler binding is always
 occupied, so an untextured mesh and a textured one are the same pipeline and
 there is no permutation to manage.

 Took a `MeshPipeline*` until M5, for the sole purpose of allocating a descriptor
 set against its layout. With push descriptors there is no set to allocate, and
 the asset table no longer needs to know that pipelines exist — which is the
 coupling this change was worth making for. A material with its own shader used
 to mean texture sets baked against a *different* pipeline's layout, legal only
 by an argument about layout compatibility that somebody had to keep true.
*>
fn void? Assets.ensure_white(&self, Gpu* gpu)
{
	if (self.has_white) return;

	self.white = gpu.create_white_texture()!;
	self.has_white = true;
}

<*
 The descriptor write for a texture, ready to push.

 Built per draw rather than once per texture, which is the trade push descriptors
 make: no pool, no allocation, no lifetime, and the cost is re-specifying sixteen
 bytes of image info at each bucket. At this project's draw counts — the whole
 thesis is that a thousand instances are one draw — that is not a cost worth
 caching to avoid.
*>
fn vk::DescriptorImageInfo Texture.descriptor(&self)
{
	return {
		.sampler = self.sampler,
		.imageView = self.view,
		.imageLayout = IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
	};
}

// ============================================================================
// The built-in triangle
// ============================================================================

<*
 A hardcoded triangle, uploaded through exactly the same path as a glTF mesh.

 This is `base_stage.md` S8 on its own: geometry reaching the shader through a
 buffer device address, with no file involved. Keeping it separate from the
 glTF path means a blank window is never ambiguous — if the triangle draws and
 a `.glb` does not, the loader is at fault and not the pipeline.

 Wound counter-clockwise as seen from +Z, which is glTF's front-face
 convention, so it is culled by the same rule real geometry is.

 @return `The asset's handle, for Scene.add_mesh.`
*>
fn AssetId? Assets.load_triangle(&self, Gpu* gpu)
{
	if (!self.started) self.init();

	Vec3[3] positions = { { -0.5, -0.5, 0 }, { 0.5, -0.5, 0 }, { 0.0, 0.5, 0 } };
	Vec3[3] normals   = { { 0, 0, 1 }, { 0, 0, 1 }, { 0, 0, 1 } };
	uint[3] indices   = { 0, 1, 2 };

	self.ensure_white(gpu)!;

	Asset asset = { .path = "<triangle>".copy(mem) };
	asset.meshes.init(mem, 1);

	GpuMesh mesh = {
		.name = "triangle".copy(mem),
		.vertex_count = 3,
		.index_count = 3,
		.has_normals = true,
		// sRGB, converted here: `base_color` is a linear factor, because glTF's
		// `baseColorFactor` is one. Written as the orange it looks like.
		.base_color = srgb_to_linear_rgb({ 0.85, 0.55, 0.25, 1.0 }),
		.texture = -1,
		.bounds = { .min = { -0.5, -0.5, 0 }, .max = { 0.5, 0.5, 0 } },
	};
	defer catch
	{
		mesh.free_buffers();
		asset.meshes.free();
		asset.path.free(mem);
	}

	mesh.positions = gpu.upload_stream(&positions, Vec3::size * 3)!;
	mesh.normals = gpu.upload_stream(&normals, Vec3::size * 3)!;
	mesh.indices = gpu.upload_indices(&indices, uint::size * 3)!;
	mesh.build_bvh(positions[..], indices[..]);

	asset.bounds = mesh.bounds;
	mesh.uploaded = true;
	mesh.gltf_mesh = -1;
	mesh.gltf_primitive = -1;
	asset.meshes.push(mesh);

	return self.claim_slot(asset);
}

// ============================================================================
// Teardown
// ============================================================================

<*
 Give back everything the upload put on the device and the CPU-side picking tree
 that goes with it — **and nothing the description owns.**

 The split exists because since G3/S3 a mesh can be given back without ceasing to
 exist. `unload_unused` frees the pieces of a kit nothing draws while the file
 stays open, and what is left has to still be a valid *described* mesh: its name,
 its bounds, its vertex count and its glTF indices, ready to be uploaded again by
 the next node that names it.

 Handles are zeroed rather than merely freed, because "is this on the device"
 is asked by testing them and a freed-but-non-null handle would answer yes.
*>
fn void GpuMesh.release_device(&self)
{
	if (self.positions.buffer != null) self.positions.free();
	if (self.indices.buffer != null) self.indices.free();
	if (self.normals.buffer != null) self.normals.free();
	if (self.uvs.buffer != null) self.uvs.free();
	self.positions = {};
	self.indices = {};
	self.normals = {};
	self.uvs = {};

	// `free_indexed` rather than `free`: the root owns the sorted-index array
	// that every node below it points into, and the plain `free` leaves it.
	if (self.bvh != null)
	{
		self.bvh.free_indexed();
		mem::free(self.bvh);
		self.bvh = null;
	}
	if (self.hull_positions.len > 0) mem::free(self.hull_positions);
	if (self.hull_triangles.len > 0) mem::free(self.hull_triangles);
	self.hull_positions = {};
	self.hull_triangles = {};
}

<*
 The above, plus the name — for when the slot itself is going away and there will
 be nothing left to describe.

 Separate from `Assets.free` because a primitive that fails partway through
 uploading has to undo its own work before anything else has heard of it.
*>
fn void GpuMesh.free_buffers(&self)
{
	self.release_device();
	// The layer stack's names and list, which are this mesh's memory exactly as
	// `name` is. The references it held are given back by `release_layers` on the
	// paths that have a live texture table to give them back to; this is the half
	// every path owes, including `Assets.free`, which has already decided to
	// destroy the table wholesale.
	self.free_layers();
	if (self.name.len > 0) self.name.free(mem);
	self.name = "";
}

fn void Assets.free(&self, Gpu* gpu)
{
	foreach (&asset : self.assets)
	{
		// A slot already swept by `unload_unused` gave everything back and left
		// its lists zeroed; walking it again would free them twice.
		if (!asset.alive) continue;
		foreach (&mesh : asset.meshes) mesh.free_buffers();
		asset.meshes.free();
		free_nodes(asset);
		free_stream(asset);
		if (asset.path.len > 0) asset.path.free(mem);
	}
	self.assets.free();
	self.free_slots.free();

	foreach (&shared : self.textures)
	{
		if (shared.alive) shared.texture.free(gpu);
	}
	self.textures.free();
	self.free_textures.free();

	if (self.has_white)
	{
		self.white.free(gpu);
		self.has_white = false;
	}


	*self = { };
}
