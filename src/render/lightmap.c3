<*
 The static light cache: what a static light does to a static surface, worked out
 once and read back as a texture.

 Shadow maps are already cached for casters that do not move. *Shading* is not:
 every frame re-evaluates every light against every pixel of a wall that has not
 changed since the level loaded. This is the other half — for the lights a script
 marks `baked` and the receivers marked `static`, the whole per-light loop becomes
 one texture read.

 ## Into an unwrap or a projected height-field chart

 TEXCOORD_0 is used when it is a layout rather than a tiling. Otherwise an
 axis-projected surface whose triangles do not overlap in that projection gets a
 separate coordinate stream; this includes uneven ground and walls as well as a
 strict plane. Material maps continue to use TEXCOORD_0. Folded geometry and
 overlapping projections remain in the real-time loop. Nothing ever goes dark: a
 light marked baked is still shaded in real time everywhere there is no tile for
 it.

 That makes eligibility the contract rather than a list. Foliage unwrapped by hand
 in Blender and re-exported joins the bake with nothing here to change.

 ## A tile per copy, not per mesh

 Two copies of one crate stand in different light, so each gets its own tile.
 `Instance.lightmap` carries the tile rather than an index, because `SV_InstanceID`
 is renumbered by culling every frame and an index into a table would name a
 different copy each time the camera moved. Sixteen bytes an instance, and the
 copies of a mesh stay one draw call.

 ## Built-in and layered material pipelines

 Built-in materials use `mesh.slang` compiled with `THREE_LIGHTMAP_BAKE`. Known
 layered materials use their generated material program so their blended normal
 maps match the frame. Arbitrary shader bodies and displaced geometry remain in
 the real-time path because the cache cannot infer what their output means.

 Area-light diffuse uses the same view-independent polygon approximation here and
 in the live frame. The numeric reference remains available for diagnostics.

 ## Seams

 A tile is rendered one texel in from its own rectangle and the border is filled
 by the same chamfer sweep `render/bake.c3` uses, so a bilinear tap at the edge of
 an island reads surface rather than the black it was cleared to. The sweep only
 ever *copies* texels, so it runs over the RGBA16F bytes without decoding them.

 ## Invalidation

 A tile is a fact about a light and a surface, so it goes stale when either
 moves. `Scene.dirty_lightmap` marks the copy beside every bump of
 `Scene.static_revision` — the same events the cached shadow map is invalidated
 by — and `JsRuntime.set_lighting` marks what a baked light's own change reaches.
 `MeshPass.resolve_lightmap` spreads a moved receiver's change to the receivers
 the baked lights could carry it to. Layered-material parameters and the camera
 invalidate their affected tiles as well, because their blended normal and
 parallax result can change the cached diffuse. `MeshPass.update_lightmap`
 re-bakes dirty tiles a few at a time under a millisecond budget; a dirty tile
 uses real-time lighting until it is current. Inside a moving caster's shadow
 footprint, the static-to-combined visibility change adjusts the cached diffuse.
 Specular always stays live. The one thing that drops the atlas is the set of
 baked lights changing, which is a different picture rather than an old one.

 ## Persistence

 `MeshPass.save_lightmap` writes version 4 of the atlas and its tile table beside
 the assets as `LIGHTMAP_MAGIC`: a header, one record per tile naming the
 receiver by node
 name, mesh index and copy index, and the tiles' texels packed one after another
 rather than the whole square — a bake fills a quarter of its atlas and the empty
 three quarters are not worth shipping. `MeshPass.load_lightmap` reads it back,
 scatters the tiles into a fresh atlas and re-bakes only the receivers whose world
 matrix has moved since.
*>
module three;

import std::collections::list;
import std::collections::map;
import std::math;
import std::math::matrix;
import std::time;
import std::io::file;
import collision;
import vk;

faultdef LIGHTMAP_NO_DEVICE, LIGHTMAP_NO_PIPELINE, LIGHTMAP_NO_ATLAS,
	LIGHTMAP_BAD_FILE, LIGHTMAP_STALE;

// RGBA16F, which is `POST_CHAIN_FORMAT` and therefore a format this project
// already renders into everywhere. Chosen over rgb9e5 because a lightmap is a
// colour *attachment* first and a sampled image second, and the shared-exponent
// format is not required to be renderable on any device — a bake that had to go
// through a second target and a conversion pass to reach it would cost more than
// the four bytes a texel it saves. The alpha channel is the coverage the seam
// sweep reads.
const vk::Format LIGHTMAP_FORMAT = FORMAT_R16G16B16A16_SFLOAT;
const usz LIGHTMAP_TEXEL_BYTES = 8;

// Texels across a metre of surface, and the atlas ceiling a bake is allowed to
// fill. Eight is about a texel every twelve centimetres, which holds a contact
// shadow on a floor and is generous on a prop.
const float LIGHTMAP_TEXELS_PER_METRE = 8.0f;
const usz LIGHTMAP_MAX_BYTES = 64 * 1024 * 1024;

// One texel of margin on each side of a tile, filled by the seam sweep, so a
// bilinear tap at the edge of the tile never reaches the tile next door.
const uint LIGHTMAP_TILE_PAD = 1;
// The smallest and largest a tile's rendered part may be. The floor is what keeps
// a hundred tiny props from each taking a texel and reading as one flat colour;
// the ceiling is what stops one ground from taking the whole budget.
const uint LIGHTMAP_TILE_MIN = 4;
const uint LIGHTMAP_TILE_MAX = 512;

// Atlas sides that are tried, smallest first.
const uint[*] LIGHTMAP_SIDES = { 256, 512, 1024, 2048, 4096, 8192 };

// How long a frame may spend catching up with the dirty tiles, and how many
// reach spheres one resolve remembers before it gives up and says "every tile".
const float LIGHTMAP_BUDGET_MS = 4.0f;
const usz LIGHTMAP_MAX_PENDING = 32;

// How many texels a catch-up batch starts at, and the ceiling it may grow to.
// The number adapts to what the budget actually pays for — see
// `MeshPass.bake_dirty_tiles` — so this is only where it starts from.
const usz LIGHTMAP_BATCH_TEXELS = 4096;
const usz LIGHTMAP_BATCH_MAX = 16 * 1024 * 1024;

// How many frames the catch-up will wait for the shadow atlas to describe the
// world the tiles are about to be baked in. Bounded, so a drag that never stops
// still gets its tiles back — one frame of shadow lag inside a drag is invisible.
const uint LIGHTMAP_SETTLE_FRAMES = 3;

<*
 One receiver's rectangle in the atlas, in texels, margin included.

 `node` is the scene slot rather than a `NodeId`, because the tile is written back
 into that node the moment the bake finishes and nothing keeps it afterwards.
*>
struct LightmapTile
{
	uint node;
	// The slot's generation when the tile was packed. A slot is recycled, and a
	// tile that kept baking into a stranger would be a prop lit as the prop that
	// used to stand there.
	uint generation;
	uint x;
	uint y;
	// The whole rectangle, margin included. The rendered part is this minus two
	// pads on each axis.
	uint size;
	// Desired inner side before atlas-wide scaling. It travels with the receiver
	// when packing sorts tiles between attempts.
	float requested_size;
	ulong material_signature;
}

struct LightmapMaterialKey @local
{
	uint material;
	uint asset;
	uint generation;
	uint mesh;
	uint variant;
	uint[4] color;
}

macro uint LightmapMaterialKey.hash(self)
{
	ulong value = ((ulong)self.material << 32) | self.asset;
	value ^= ((ulong)self.generation << 32) | self.mesh;
	value ^= ((ulong)self.variant << 32) | self.color[0];
	value ^= ((ulong)self.color[1] << 32) | self.color[2];
	value ^= self.color[3];
	value *= 0x9E3779B97F4A7C15;
	return (uint)(value ^ (value >> 32));
}

fn bool LightmapMaterialKey.equals(self, LightmapMaterialKey other) @operator(==)
{
	if (self.material != other.material || self.asset != other.asset
		|| self.generation != other.generation || self.mesh != other.mesh
		|| self.variant != other.variant) return false;
	for (uint i = 0; i < 4; i++) if (self.color[i] != other.color[i]) return false;
	return true;
}

alias LightmapMaterialSignatures = HashMap{LightmapMaterialKey, ulong};

fn ulong MeshPass.lightmap_material_signature(&self, Node* node)
{
	Material* material = self.material(node.material);
	GpuMesh* mesh = self.assets.mesh(node.asset, node.mesh);
	ulong signature = hash_bytes(KEY_SEED, &node.variant, uint::size);
	if (material == null || mesh == null) return signature;
	signature = hash_bytes(signature, &material.block, PUSH_BUDGET);
	if (material.table.len > 0) signature = hash_bytes(signature, material.table.ptr, material.table.len);
	// These inputs live beside the material's reflected block, but still alter the
	// final normal and therefore the diffuse irradiance stored in the tile.
	signature = hash_bytes(signature, &material.uv_transform, float[4]::size);
	signature = hash_bytes(signature, &material.uv_variant_count, uint::size);
	signature = hash_bytes(signature, &material.uv_variants, UvVariant[UV_VARIANTS]::size);
	signature = hash_bytes(signature, &material.stochastic, bool::size);
	uint map_flags = self.map_flags(material);
	signature = hash_bytes(signature, &map_flags, uint::size);
	signature = hash_bytes(signature, &mesh.base_color, float[4]::size);
	signature = hash_bytes(signature, &node.color, float[4]::size);
	uint[DRAW_TEXTURE_INDICES] textures = texture_index_row(&self.assets, material, mesh);
	signature = hash_bytes(signature, &textures, uint[DRAW_TEXTURE_INDICES]::size);
	// A decoded image may replace its contents without changing its bindless slot.
	return hash_bytes(signature, &self.assets.revision, uint::size);
}

struct LightmapMaterialPipeline
{
	uint material;
	MeshPipeline pipeline;
	bool ready;
}

// A sphere a change reaches, in world space. A radius at or below zero is a
// light with no place to be — a directional one — and reaches every tile.
struct LightmapReach
{
	Vec3 centre;
	float radius;
}

// How far a light's own change carries. An area light's range is measured from
// its surface, so its half extents are added on.
fn LightmapReach light_reach(Light light)
{
	if (light.meta[2] == 0 || light.direction[3] <= 0) return { { 0, 0, 0 }, 0 };
	float radius = light.direction[3];
	if (light.meta[2] == 2 || light.meta[2] == 3)
	{
		radius += math::max(light.area_right[3], light.area_up[3]);
	}
	return { { light.direction[0], light.direction[1], light.direction[2] }, radius };
}

// Whether anything inside this box could be reached.
fn bool LightmapReach.covers(&self, collision::Aabb3 box)
{
	if (self.radius <= 0) return true;
	Vec3 away = math::min(math::max(self.centre, box.min), box.max) - self.centre;
	return away.dot(away) <= self.radius * self.radius;
}

// Whether two lights differ in a way a lightmap tile would show. `meta.y` is the
// shadow view index and churns every frame; everything else counts, the shadow
// settings in `meta.w` included — a light that gained a shadow map casts one.
// The baked bit itself changes atlas eligibility, not the texels already in it.
fn bool lights_differ(Light a, Light b)
{
	return a.direction != b.direction || a.color != b.color
		|| a.area_right != b.area_right || a.area_up != b.area_up
		|| a.meta[0] != b.meta[0] || a.meta[2] != b.meta[2]
		|| (a.meta[3] & ~LIGHT_BAKED) != (b.meta[3] & ~LIGHT_BAKED);
}

fn bool Lightmap.tracks_light(&self, Light light)
{
	foreach (baked : self.baked_lights)
	{
		if (baked.meta[0] == light.meta[0]) return light_is_baked(baked);
	}
	return false;
}

// What `three.lights.bake()` was asked for.
struct LightmapOptions
{
	float texels_per_metre;
	usz max_bytes;
	// How much bake work a frame may do to catch up with the dirty tiles.
	float budget_ms;
}

const LightmapOptions DEFAULT_LIGHTMAP_OPTIONS = {
	.texels_per_metre = LIGHTMAP_TEXELS_PER_METRE,
	.max_bytes = LIGHTMAP_MAX_BYTES,
	.budget_ms = LIGHTMAP_BUDGET_MS,
};

// What it answers with, and what `stats()` reports afterwards.
struct LightmapResult
{
	uint receivers;
	uint skipped;
	usz texels;
	usz bytes;
	double ms;
}

struct Lightmap
{
	vk::Image image;
	vk::ImageView view;
	vk::Sampler sampler;
	vk::Memory memory;
	uint side;
	// The atlas holds a bake. False before the first one and after a scene switch,
	// and what makes the binding fall back to the shared white image.
	bool live;

	// `mesh.slang` under `THREE_LIGHTMAP_BAKE`, compiled on the first bake and
	// kept. A compile that failed once is not retried.
	MeshPipeline pipeline;
	bool pipeline_ready;
	bool pipeline_refused;
	List{LightmapMaterialPipeline} material_pipelines;

	// The four buffers one bake's draws read through `MeshPush`, plus the readback
	// the seam sweep works in. One each rather than one per frame in flight: a bake
	// submits and waits, so there is no frame to race with.
	vk::Memory frame;
	vk::Memory lights;
	vk::Memory views;
	vk::Memory instances;
	vk::Memory draws;
	vk::Memory staging;

	// Which lights the atlas holds, folded over their stable ids. A frame whose
	// baked set is not this one stops reading the atlas altogether: the tile is a
	// sum over the lights that were baked, so a light taken back out of the set
	// would be shaded in real time *and* still be in the tile.
	//
	// The one invalidation that drops the atlas rather than re-baking part of it,
	// because the light set changing is a different picture and not a stale one.
	uint signature;
	// The light state represented by the atlas. Kept while a baked flag is
	// temporarily off so movement during that interval still dirties its tiles.
	List{Light} baked_lights;

	<*
	 The packing, kept for the life of the atlas.

	 The full bake used to throw this away the moment it had written each rectangle
	 into its node. Re-baking one tile needs it back: the rectangles must not move,
	 or every copy the re-bake did not touch would read somebody else's light.
	*>
	List{LightmapTile} tiles;
	// Which scene was packed. A different one has different nodes behind the same
	// slots, so its tiles are not these.
	uint scene_id;
	// The density the tiles were actually packed at — the requested one after the
	// shrink that made the atlas fit. Written into the file and reported back.
	float density;

	// Moves whenever a texel of the atlas changes, and is folded into
	// `MeshPass.frame_key`: a re-baked tile is a different picture with the same
	// buffers, which is exactly what the frame skip would otherwise miss.
	uint revision;

	<*
	 The catch-up state — see the file's header.

	 `dirty` is how many tiles are waiting, and `stats().lightmapDirty`. `seen` is
	 the `Scene.lightmap_changes` this resolved last, so a frame where nothing
	 moved does not walk the node pool. `pending` is what the next resolve has to
	 spread: a moved light's reach, or a moved receiver's lights' reaches.
	*>
	uint dirty;
	uint seen;
	LightmapReach[LIGHTMAP_MAX_PENDING] pending;
	uint pending_count;
	bool pending_all;
	float budget_ms;
	// How many texels the next catch-up batch takes, halved when a batch overran
	// the budget and doubled when it used less than half of it. A number that
	// finds its own level rather than a cost model: a batch is two submissions and
	// a readback as well as the shading, and the shares move with the device.
	usz batch_texels;
	// Frames still to wait before re-baking, and how many have been waited in a
	// row. A bake reads the shadow atlas as the last frame left it.
	uint settle;
	uint stalled;
	ulong camera_signature;
	LightmapResult last;
}

// Remembers a sphere the next resolve has to spread, or gives up and says every
// tile — which is the same answer, arrived at without a list.
fn void Lightmap.push_reach(&self, LightmapReach reach)
{
	if (reach.radius <= 0 || self.pending_count >= LIGHTMAP_MAX_PENDING)
	{
		self.pending_all = true;
		return;
	}
	self.pending[self.pending_count++] = reach;
}

// The baked lights, by stable registry id — `Lightmap.signature`.
fn uint MeshPass.baked_light_signature(&self)
{
	uint signature = 2166136261u;
	for (uint i = 0; i < self.lighting.count; i++)
	{
		if (!light_is_baked(self.lighting.lights[i])) continue;
		signature = (signature ^ (self.lighting.lights[i].meta[0] + 1)) * 16777619u;
	}
	return signature;
}

// Whether this frame's copies may read their tiles. Called once per frame, before
// the draw list copies `Node.lightmap` into the instances.
fn void MeshPass.refresh_lightmap(&self)
{
	if (self.scene == null) return;
	self.scene.lightmap_live = self.lightmap.live && self.lightmap.scene_id == self.scene.id
		&& self.baked_light_signature() == self.lightmap.signature;
}

// Called after shadow planning, when the current update state is finally known.
fn void MeshPass.finalize_lightmap(&self)
{
	if (self.scene == null || !self.scene.lightmap_live) return;
	bool live = self.shadow_manager.plan != SHADOW_PLAN_FULL
		|| (!self.shadows.live && !self.point_shadows.live);
	if (live) return;
	self.scene.lightmap_live = false;
	foreach (bucket : self.scene.buckets)
	{
		for (uint i = 0; i < bucket.count; i++)
		{
			self.shadow_instances[bucket.first + i].lightmap = { 0, 0, 0, 0 };
		}
	}
}

<*
 What a write to the lighting registry does to the tiles.

 Called with the lighting about to be installed, so both readings of a light that
 moved are in hand: a tile where it *was* is as stale as one where it is now, and
 dirtying only the second would leave the old pool of light standing.

 A change to the *set* of baked lights is deliberately not marked. The signature
 stops matching and the atlas is ignored whole, which is the stronger answer and
 the one `light.baked = false` has always given.
*>
fn void MeshPass.note_lighting_change(&self, Lighting next)
{
	Lightmap* map = &self.lightmap;
	if (!map.live || self.scene == null || map.scene_id != self.scene.id) return;

	uint count = math::max(next.count, self.lighting.count);
	if (count > MAX_LIGHTS) count = MAX_LIGHTS;
	bool moved = false;
	for (uint i = 0; i < count; i++)
	{
		bool was_baked = i < self.lighting.count && light_is_baked(self.lighting.lights[i]);
		bool now_baked = i < next.count && light_is_baked(next.lights[i]);
		bool tracked_was = i < self.lighting.count && map.tracks_light(self.lighting.lights[i]);
		bool tracked_now = i < next.count && map.tracks_light(next.lights[i]);
		bool tracked = tracked_was || tracked_now;
		if (!was_baked && !now_baked && !tracked) continue;
		if (i < self.lighting.count && i < next.count
			&& self.lighting.lights[i].meta[0] == next.lights[i].meta[0]
			&& !lights_differ(self.lighting.lights[i], next.lights[i])) continue;
		if ((was_baked || tracked_was) && i < self.lighting.count)
		{
			map.push_reach(light_reach(self.lighting.lights[i]));
		}
		if ((now_baked || tracked_now) && i < next.count) map.push_reach(light_reach(next.lights[i]));
		moved = true;
	}
	if (moved) self.scene.lightmap_changes++;
}

<*
 Catches the atlas up with what has moved, a few tiles a frame.

 At the top of `prepare` rather than beside `refresh_lightmap` further down,
 because a bake reads the shadow atlas as the *last* frame left it and the packed
 view table has to be the one that describes those texels — which is true here and
 stops being true the moment `prepare_shadow_manager` has run.

 The budget is wall clock around a submission that waits, so it is the GPU's time
 as well as the CPU's. Always at least one tile: a budget smaller than the tile in
 front of it would otherwise never finish anything.
*>
fn void MeshPass.update_lightmap(&self, Gpu* gpu)
{
	Lightmap* map = &self.lightmap;
	if (self.scene == null || !map.live || map.scene_id != self.scene.id) return;
	if (self.baked_light_signature() != map.signature) return;
	Vec3 eye = self.camera.eye();
	Matrix4f camera_view_projection = self.camera.view_projection(self.aspect);
	ulong camera_signature = hash_bytes(KEY_SEED, &eye, Vec3::size);
	camera_signature = hash_bytes(camera_signature, &camera_view_projection, Matrix4f::size);
	if (map.live && map.camera_signature != camera_signature)
	{
		foreach (tile : map.tiles)
		{
			Node* node = &self.scene.nodes[tile.node];
			Material* material = self.material(node.material);
			if (material == null || !material.script_layers.present) continue;
			node.lightmap_dirty = true;
			node.lightmap = { 0, 0, 0, 0 };
		}
		map.camera_signature = camera_signature;
		self.scene.lightmap_changes++;
	}
	@pool()
	{
		// Re-read materials every frame so direct uniform writes are observed, but
		// hash identical receiver/material state only once.
		LightmapMaterialSignatures signatures;
		signatures.tinit();
		foreach (&tile : map.tiles)
		{
			Node* node = &self.scene.nodes[tile.node];
			LightmapMaterialKey key = {
				.material = node.material,
				.asset = node.asset.index,
				.generation = node.asset.generation,
				.mesh = node.mesh,
				.variant = node.variant,
				.color = {
					bitcast(node.color[0], uint), bitcast(node.color[1], uint),
					bitcast(node.color[2], uint), bitcast(node.color[3], uint),
				},
			};
			ulong? cached = signatures.get(key);
			ulong material_signature;
			if (try cached)
			{
				material_signature = cached;
			}
			else
			{
				material_signature = self.lightmap_material_signature(node);
				signatures.set(key, material_signature);
			}
			if (tile.material_signature == material_signature) continue;
			tile.material_signature = material_signature;
			node.lightmap_dirty = true;
			node.lightmap = { 0, 0, 0, 0 };
			self.scene.lightmap_changes++;
		}
	};

	if (self.scene.lightmap_changes != map.seen || self.scene.lightmap_dirty_all
		|| map.pending_count > 0 || map.pending_all)
	{
		// The boxes the reach is tested against are the world's, so the walk that
		// makes them current has to have happened. Cached: the second call inside
		// `prepare` is a compare.
		self.scene.update_world_matrices();
		self.resolve_lightmap();
		map.seen = self.scene.lightmap_changes;
		// The shadow atlas still holds the world as it was before this change, and a
		// tile baked against it would cache the shadow of where the light used to
		// stand. One frame is what it takes for the shadow pass to catch up.
		if (map.dirty > 0) map.settle = 1;
	}
	if (map.dirty == 0) return;

	bool ready = map.settle == 0 && self.shadow_manager.deferred == 0;
	if (!ready && map.stalled < LIGHTMAP_SETTLE_FRAMES)
	{
		if (map.settle > 0) map.settle--;
		map.stalled++;
		return;
	}
	map.settle = 0;
	map.stalled = 0;
	self.bake_dirty_tiles(gpu);
}

// One node's world box, or the point it stands at when there is no mesh to fit
// one around — a group that moved is still something a light reaches.
fn collision::Aabb3 MeshPass.node_lightmap_box(&self, Node* node)
{
	GpuMesh* mesh = node.asset.is_set() && node.mesh != NO_MESH
		? self.assets.mesh(node.asset, node.mesh) : null;
	if (mesh == null)
	{
		Vec3 at = { node.world.m[12], node.world.m[13], node.world.m[14] };
		return { at, at };
	}
	return self.scene.node_world_box(node, mesh);
}

<*
 Turns what changed into which tiles are stale.

 Two steps and the first is the conservative one. A receiver that moved changes
 the light on everything the baked lights could carry its new shadow to, and there
 is no cheap exact answer to *what* it shadows — so its change becomes the reach
 of every baked light that can see it, and every tile inside one of those reaches
 is dirty. A light that moved arrives here as its own reach, from
 `note_lighting_change`.

 A dirty tile is not displayed. The ordinary light loop is more work, but it is
 also the only correct answer while a moving caster or light has made the cached
 shadowing stale.
*>
fn void MeshPass.resolve_lightmap(&self)
{
	Lightmap* map = &self.lightmap;
	Scene* scene = self.scene;
	if (scene.lightmap_dirty_all)
	{
		map.pending_all = true;
		scene.lightmap_dirty_all = false;
	}

	foreach (&node : scene.nodes)
	{
		if (!node.lightmap_seed) continue;
		node.lightmap_seed = false;
		if (!node.alive || map.pending_all) continue;
		collision::Aabb3 box = self.node_lightmap_box(node);
		for (uint i = 0; i < self.lighting.count; i++)
		{
			if (!light_is_baked(self.lighting.lights[i])) continue;
			LightmapReach reach = light_reach(self.lighting.lights[i]);
			if (reach.covers(box)) map.push_reach(reach);
		}
	}

	uint dirty = 0;
	foreach (tile : map.tiles)
	{
		Node* node = &scene.nodes[tile.node];
		if (!node.alive || node.generation != tile.generation) continue;
		if (!node.lightmap_dirty && (map.pending_all || map.pending_count > 0))
		{
			if (map.pending_all)
			{
				node.lightmap_dirty = true;
			}
			else
			{
				collision::Aabb3 box = self.node_lightmap_box(node);
				for (uint i = 0; i < map.pending_count; i++)
				{
					if (!map.pending[i].covers(box)) continue;
					node.lightmap_dirty = true;
					break;
				}
			}
		}
		if (node.lightmap_dirty)
		{
			node.lightmap = { 0, 0, 0, 0 };
			dirty++;
		}
	}
	map.dirty = dirty;
	map.pending_count = 0;
	map.pending_all = false;
}

<*
 Re-bakes as many dirty tiles as the budget pays for, into the rectangles they
 already hold.

 The batch is sized before it is submitted, from what a texel of tile cost last
 time — the whole bake seeds the number and each batch big enough to be worth
 believing refines it. A small batch is mostly the two submissions' own overhead
 and says nothing about the tiles, so it is measured and not learned from.
*>
fn void MeshPass.bake_dirty_tiles(&self, Gpu* gpu)
{
	Lightmap* map = &self.lightmap;
	if (map.image == null || !map.pipeline_ready || map.tiles.len() == 0) return;
	double budget = (double)(map.budget_ms > 0 ? map.budget_ms : LIGHTMAP_BUDGET_MS);
	if (budget <= 0) return;
	if (map.batch_texels == 0) map.batch_texels = LIGHTMAP_BATCH_TEXELS;

	@pool()
	{
		LightmapTile[] queue = alloc::new_array(tmem, LightmapTile, map.tiles.len());
		sz count = 0;
		foreach (tile : map.tiles)
		{
			Node* node = &self.scene.nodes[tile.node];
			if (!node.alive || node.generation != tile.generation || !node.lightmap_dirty) continue;
			// A copy that stopped being a static receiver keeps its rectangle in the
			// packing and no longer reads it, so re-baking it is work for nobody.
			if (!node.static_caster)
			{
				node.lightmap_dirty = false;
				continue;
			}
			queue[count++] = tile;
		}
		map.dirty = (uint)count;
		if (count == 0) return;

		Clock started = clock::now();
		sz at = 0;
		while (at < count)
		{
			if (at > 0 && (double)started.to_now() / 1_000_000.0 >= budget) break;
			sz take = 0;
			usz texels = 0;
			while (at + take < count)
			{
				usz one = (usz)queue[at + take].size * (usz)queue[at + take].size;
				if (take > 0 && texels + one > map.batch_texels) break;
				texels += one;
				take++;
			}
			if (take == 0) take = 1;

			Clock batch = clock::now();
			if (catch self.record_lightmap(gpu, queue[at:take], map.side, whole: false)) return;
			double took = (double)batch.to_now() / 1_000_000.0;

			// Where the batch size comes from. Halved on an overrun so a frame that
			// blew the budget does not blow the next one too, doubled while there is
			// room, and never below the tile in front of it.
			if (took > budget)
			{
				map.batch_texels = map.batch_texels > 2 ? map.batch_texels / 2 : 1;
			}
			else if (took < budget * 0.5 && map.batch_texels < LIGHTMAP_BATCH_MAX)
			{
				map.batch_texels *= 2;
			}
			for (sz i = 0; i < take; i++)
			{
				LightmapTile tile = queue[at + i];
				Node* node = &self.scene.nodes[tile.node];
				float inv = 1.0f / (float)map.side;
				uint inner = tile.size - 2 * LIGHTMAP_TILE_PAD;
				node.lightmap = {
					(float)(tile.x + LIGHTMAP_TILE_PAD) * inv,
					(float)(tile.y + LIGHTMAP_TILE_PAD) * inv,
					(float)inner * inv,
					(float)inner * inv,
				};
				node.lightmap_dirty = false;
				if (map.dirty > 0) map.dirty--;
			}
			at += take;
		}
	};
}

fn usz Lightmap.bytes(&self) => self.image != null ? (usz)self.memory.size : 0;

fn vk::DescriptorImageInfo Lightmap.descriptor(&self) => {
	.sampler = self.sampler, .imageView = self.view, .imageLayout = IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
};

fn void Lightmap.free_buffers(&self)
{
	if (self.frame.buffer != null) self.frame.free();
	if (self.lights.buffer != null) self.lights.free();
	if (self.views.buffer != null) self.views.free();
	if (self.instances.buffer != null) self.instances.free();
	if (self.draws.buffer != null) self.draws.free();
	if (self.staging.buffer != null) self.staging.free();
	self.frame = { };
	self.lights = { };
	self.views = { };
	self.instances = { };
	self.draws = { };
	self.staging = { };
}

fn void Lightmap.free_image(&self, Gpu* gpu)
{
	if (self.image == null) return;
	gpu.retire_memory(self.memory, self.view, self.sampler);
	self.image = (vk::Image)null;
	self.view = (vk::ImageView)null;
	self.sampler = (vk::Sampler)null;
	self.memory = { };
	self.side = 0;
	self.live = false;
}

fn void Lightmap.free(&self, Gpu* gpu)
{
	self.free_buffers();
	self.free_image(gpu);
	if (self.pipeline_ready) self.pipeline.free(gpu);
	foreach (&entry : self.material_pipelines) if (entry.ready) entry.pipeline.free(gpu);
	if (self.material_pipelines.allocator != null) self.material_pipelines.free();
	if (self.tiles.allocator != null) self.tiles.free();
	if (self.baked_lights.allocator != null) self.baked_lights.free();
	LightmapResult last = self.last;
	*self = { };
	self.last = last;
}

fn MeshPipeline*? MeshPass.lightmap_pipeline_for(&self, Gpu* gpu, uint material_index)
{
	Material* material = self.material(material_index);
	if (material == null || !material.script_layers.present || material.vertex.len > 0) return null;
	Lightmap* map = &self.lightmap;
	if (map.material_pipelines.allocator == null) map.material_pipelines.init(mem, 4);
	foreach (&known : map.material_pipelines)
		if (known.material == material_index) return known.ready ? &known.pipeline : null;

	LightmapMaterialPipeline entry = { .material = material_index };
	@pool()
	{
		String? source = material_source(material.fragment, material.declared_uniforms, tmem,
			material.declared_textures, material.vertex, lightmap: true);
		if (try source)
		{
			ShaderModule mod = compile_slang(source, "three.lightmap", MESH_ENTRIES[..])!;
			defer mod.free();
			if (mod.ok)
			{
				entry.pipeline.init_post(gpu, &mod, LIGHTMAP_FORMAT, MESH_PUSH_FIELDS[..])!;
				entry.ready = true;
			}
		}
	};
	map.material_pipelines.push(entry);
	sz last = map.material_pipelines.len() - 1;
	return map.material_pipelines[last].ready ? &map.material_pipelines[last].pipeline : null;
}

<*
 `mesh.slang` compiled to write light into a tile instead of colour onto a screen.

 `init_post` rather than `init` and that is the whole of the difference in state:
 no depth attachment — a uv-space rasterisation has nothing to occlude — and
 `CULL_MODE_NONE`, because a triangle's winding in uv space is its island's and
 says nothing about which way the surface faces.
*>
fn void? Lightmap.ensure_pipeline(&self, Gpu* gpu)
{
	if (self.pipeline_ready) return;
	if (self.pipeline_refused) return LIGHTMAP_NO_PIPELINE~;
	self.pipeline_refused = true;

	@pool()
	{
		String source = shader_source("mesh.slang", tmem)!;
		DString variant;
		variant.tinit(source.len + 128);
		// `#line 1` after the defines so a Slang diagnostic still names the line the
		// file has. `THREE_NO_AO` drops a sampler that reads the camera's depth
		// buffer, which a bake does not have. `THREE_AREA_REFERENCE` keeps numeric
		// specular helpers available; lightmap diffuse still uses the live polygon.
		variant.append_string("#define THREE_LIGHTMAP_BAKE 1\n#define THREE_NO_AO 1\n");
		variant.append_string("#define THREE_AREA_REFERENCE 1\n#line 1\n");
		variant.append_string(source);

		ShaderModule mod = compile_slang(variant.str_view(), "mesh.slang", MESH_ENTRIES[..])!;
		defer mod.free();
		if (!mod.ok)
		{
			@advise("three: the lightmap bake shader would not compile: %s", mod.diagnostic);
			return LIGHTMAP_NO_PIPELINE~;
		}
		self.pipeline.init_post(gpu, &mod, LIGHTMAP_FORMAT, MESH_PUSH_FIELDS[..])!;
	};
	self.pipeline_ready = true;
	self.pipeline_refused = false;
}

<*
 The atlas image, at `side` texels a side, plus the sampler that reads it.

 Recreated whenever the side changes, which is every bake that packs differently.
*>
fn void? Lightmap.ensure_image(&self, Gpu* gpu, uint side)
{
	if (self.image != null && self.side == side) return;
	self.free_image(gpu);

	defer catch
	{
		if (self.view != null) vk::destroyImageView(gpu.handle, self.view, null);
		if (self.memory.image != null) { self.memory.free(); }
		else if (self.image != null) { vk::destroyImage(gpu.handle, self.image, null); }
		self.image = (vk::Image)null;
		self.view = (vk::ImageView)null;
		self.memory = { };
	}

	self.image = vk::imageCreateInfo().setImageType(IMAGE_TYPE_2D).setFormat(LIGHTMAP_FORMAT)
		.setExtent({ .width = side, .height = side, .depth = 1 })
		.setMipLevels(1).setArrayLayers(1).setSamples(SAMPLE_COUNT_1_BIT)
		.setTiling(IMAGE_TILING_OPTIMAL)
		.setUsage(IMAGE_USAGE_COLOR_ATTACHMENT_BIT | IMAGE_USAGE_SAMPLED_BIT
			| IMAGE_USAGE_TRANSFER_SRC_BIT | IMAGE_USAGE_TRANSFER_DST_BIT)
		.setInitialLayout(IMAGE_LAYOUT_UNDEFINED).build(gpu.handle)!;
	self.memory = vk::create_image_buffer(self.image, &gpu.allocator, MEMORY_PROPERTY_DEVICE_LOCAL_BIT)!;
	self.view = vk::imageViewCreateInfo().setViewType(IMAGE_VIEW_TYPE_2D).setFormat(LIGHTMAP_FORMAT)
		.setSubresourceRange(COLOR_LEVEL).setImage(self.image).build(gpu.handle)!;
	if (self.sampler == null)
	{
		// Linear and clamped: the tile is a picture of a surface, so it wants
		// filtering, and the margin is what keeps a tap inside its own tile.
		self.sampler = vk::samplerCreateInfo().setMagFilter(FILTER_LINEAR).setMinFilter(FILTER_LINEAR)
			.setAddressModeU(SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE).setAddressModeV(SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE)
			.setAddressModeW(SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE).setMipmapMode(SAMPLER_MIPMAP_MODE_NEAREST)
			.setMinLod(0).setMaxLod(0).setBorderColor(BORDER_COLOR_FLOAT_TRANSPARENT_BLACK).build(gpu.handle)!;
	}
	self.side = side;
}

// How much a node's world matrix scales an area: the cube root of its
// determinant, squared. Exact for a uniform scale and the right magnitude for
// anything else.
fn float lightmap_area_scale(Matrix4f world) @local
{
	Matrix3f linear = {
		.m = { world.m[0], world.m[1], world.m[2], world.m[4], world.m[5], world.m[6],
			world.m[8], world.m[9], world.m[10] }
	};
	float det = math::abs(linear.determinant());
	if (det <= 1e-12f) return 0;
	float side = (float)math::pow((double)det, 1.0 / 3.0);
	return side * side;
}

// Shelf packing, largest first. Enough for a set of squares: the sort makes the
// rows even, and a lightmap atlas is repacked from nothing every bake rather than
// grown.
fn bool lightmap_pack(LightmapTile[] tiles, uint side) @local
{
	uint x = 0;
	uint y = 0;
	uint row = 0;
	foreach (&tile : tiles)
	{
		if (tile.size > side) return false;
		if (x + tile.size > side)
		{
			x = 0;
			y += row;
			row = 0;
		}
		if (y + tile.size > side) return false;
		tile.x = x;
		tile.y = y;
		x += tile.size;
		if (tile.size > row) row = tile.size;
	}
	return true;
}

<*
 Fills the texels no triangle covered, inside one tile.

 The two-pass chamfer sweep `render/bake.c3` explains, over an RGBA16F rectangle
 of a larger image. It only ever *copies* a texel's colour, so it does not decode
 the halves; the alpha is what says which texels were written, and it is left
 exactly where the rasteriser put it.
*>
fn void lightmap_dilate(char[] texels, uint stride, LightmapTile tile, uint[] spread) @local
{
	uint size = tile.size;
	sz count = (sz)size * (sz)size;
	if (spread.len < count) return;

	for (uint y = 0; y < size; y++)
	{
		for (uint x = 0; x < size; x++)
		{
			sz at = ((sz)(tile.y + y) * (sz)stride + (sz)(tile.x + x)) * (sz)LIGHTMAP_TEXEL_BYTES;
			bool written = texels[at + 6] != 0 || texels[at + 7] != 0;
			spread[(sz)y * (sz)size + (sz)x] = written ? 0 : uint::max;
		}
	}
	for (uint y = 0; y < size; y++)
	{
		for (uint x = 0; x < size; x++)
		{
			lightmap_reach(texels, stride, tile, spread, x, y, x - 1, y);
			lightmap_reach(texels, stride, tile, spread, x, y, x, y - 1);
			lightmap_reach(texels, stride, tile, spread, x, y, x - 1, y - 1);
			lightmap_reach(texels, stride, tile, spread, x, y, x + 1, y - 1);
		}
	}
	for (uint y = size; y > 0; y--)
	{
		for (uint x = size; x > 0; x--)
		{
			lightmap_reach(texels, stride, tile, spread, x - 1, y - 1, x, y - 1);
			lightmap_reach(texels, stride, tile, spread, x - 1, y - 1, x - 1, y);
			lightmap_reach(texels, stride, tile, spread, x - 1, y - 1, x, y);
			lightmap_reach(texels, stride, tile, spread, x - 1, y - 1, x - 2, y);
		}
	}
}

// One step of the sweep. The coordinates are tile-local and unsigned, so a step
// off an edge wraps to a very large number and the bounds test catches it either
// way — `MaterialBaker.reach`'s arrangement exactly.
fn void lightmap_reach(char[] texels, uint stride, LightmapTile tile, uint[] spread,
	uint x, uint y, uint fx, uint fy) @local
{
	uint size = tile.size;
	if (x >= size || y >= size || fx >= size || fy >= size) return;
	sz to = (sz)y * (sz)size + (sz)x;
	sz from = (sz)fy * (sz)size + (sz)fx;
	if (spread[from] == uint::max) return;
	uint reached = spread[from] + 1;
	if (reached >= spread[to]) return;
	spread[to] = reached;

	sz dst = ((sz)(tile.y + y) * (sz)stride + (sz)(tile.x + x)) * (sz)LIGHTMAP_TEXEL_BYTES;
	sz src = ((sz)(tile.y + fy) * (sz)stride + (sz)(tile.x + fx)) * (sz)LIGHTMAP_TEXEL_BYTES;
	for (sz i = 0; i < 6; i++) texels[dst + i] = texels[src + i];
}

<*
 Every copy this scene can hold a tile for, in slot order.

 One walk shared by the bake and by `load_lightmap`, because "which copies are
 receivers" has to be the same question in both: a load matches a file's tiles
 against this list, and a list that disagreed with the one the save was made from
 would refuse a good file.

 @param slots : `Filled with the node slots, in order. At least as long as the node pool.`
 @param wanted : `Filled with the tile side each receiver asks for at the given density. Empty asks only for the slots.`
 @param skipped : `Counts the static receivers refused a tile, if it is wanted.`
 @return `How many receivers there are.`
*>
fn uint MeshPass.lightmap_receivers(&self, uint[] slots, float[] wanted, float density = 0,
	uint* skipped = null)
{
	uint found = 0;
	foreach (slot, &node : self.scene.nodes)
	{
		if (!node.alive || !node.asset.is_set() || node.mesh == NO_MESH) continue;
		if (node.collision_only || !node.static_caster) continue;
		GpuMesh* mesh = self.assets.mesh(node.asset, node.mesh);
		if (mesh == null || !mesh.uploaded || mesh.index_count < 3) continue;
		// A posed mesh is not the shape its uvs describe from one frame to the next,
		// and `set_static_caster` already refuses a pre-skinned one.
		if (node.skin >= 0 || node.preskinned) { if (skipped != null) (*skipped)++; continue; }
		if ((!mesh.has_uvs && !mesh.lightmap_generated) || !mesh.lightmap_eligible
			|| mesh.lightmap_uv_area <= 0)
		{
			if (skipped != null) (*skipped)++;
			continue;
		}
		// A material holding every sampler slot it may declare has none left for the
		// lightmap, so its shader has no binding to read one through — see
		// `THREE_NO_LIGHTMAP` in `shader/assemble.c3`. Asked of the reflected layout
		// rather than of the texture count, so the two cannot drift.
		Material* material = self.material(node.material);
		// A generated chart is safe for the built-in material, whose normal map the
		// bake evaluates below. An arbitrary body may displace the vertex or replace
		// the normal, and the generic bake cannot reproduce that program.
		bool layered = material != null && material.script_layers.present && material.vertex.len == 0;
		if (!self.shades_built_in(material) && !layered)
		{
			if (skipped != null) (*skipped)++;
			continue;
		}
		if (material != null && material.pipeline != null
			&& !pipeline_declares_binding(material.pipeline, LIGHTMAP_BINDING))
		{
			if (skipped != null) (*skipped)++;
			continue;
		}
		float area = mesh.lightmap_local_area * lightmap_area_scale(node.world);
		if (area <= 0) { if (skipped != null) (*skipped)++; continue; }
		if (found >= slots.len) break;
		slots[found] = (uint)slot;
		// Texels a metre becomes texels a tile through how much surface one unit of
		// uv carries: a tile of N holds N² texels over `uv_area` of the square, so
		// N = density × sqrt(area / uv_area).
		if (wanted.len > found)
		{
			wanted[found] = density * (float)math::sqrt((double)(area / mesh.lightmap_uv_area));
		}
		found++;
	}
	return found;
}

<*
 Bakes every eligible static receiver against every baked light.

 Synchronous: one submission, one wait, one readback and one upload, which is the
 right trade for a verb a script calls at the end of a load. It reads the shadow
 atlas **as the last frame left it**, so a light whose shadow was not resident
 that frame bakes without one — `three.lights.shadow.maxLocal` is what decides
 that, and `docs/functions.md` says to raise it before baking a scene of ten
 lights.

 Every node's tile is cleared first, so a second call replaces the first rather
 than leaving copies pointing into an atlas that has been repacked.

 @return ? LIGHTMAP_NO_DEVICE : `No GPU. Nothing to run the bake on.`
 @return ? LIGHTMAP_NO_ATLAS : `Nothing eligible, or nothing that fits the byte budget.`
*>
fn LightmapResult? MeshPass.bake_lightmaps(&self, LightmapOptions options)
{
	Gpu* gpu = self.assets.gpu;
	if (gpu == null || gpu.handle == null) return LIGHTMAP_NO_DEVICE~;
	if (self.scene == null) return LIGHTMAP_NO_ATLAS~;

	Clock started = clock::now();
	Lightmap* map = &self.lightmap;
	map.ensure_pipeline(gpu)!;

	float density = options.texels_per_metre > 0 ? options.texels_per_metre : LIGHTMAP_TEXELS_PER_METRE;
	usz budget = options.max_bytes > 0 ? options.max_bytes : LIGHTMAP_MAX_BYTES;

	// Every copy loses its tile before anything is measured: an atlas that is about
	// to be repacked must not be read through last bake's rectangles, and a node
	// that has stopped being eligible must stop being lightmapped.
	foreach (&node : self.scene.nodes)
	{
		node.lightmap = { 0, 0, 0, 0 };
		node.lightmap_dirty = false;
		node.lightmap_seed = false;
	}
	map.clear_dirty();
	self.scene.lightmap_dirty_all = false;
	map.live = false;
	self.scene.lightmap_live = false;

	List{LightmapTile} tiles;
	tiles.init(mem, 64);
	defer tiles.free();
	uint skipped = 0;
	sz pool = self.scene.nodes.len();
	if (pool == 0) return LIGHTMAP_NO_ATLAS~;
	uint[] slots = mem::new_array(uint, pool);
	defer mem::free(slots);
	float[] sides = mem::new_array(float, pool);
	defer mem::free(sides);
	uint found = self.lightmap_receivers(slots, sides, density, &skipped);
	for (uint i = 0; i < found; i++)
	{
		tiles.push({
			.node = slots[i], .generation = self.scene.nodes[slots[i]].generation,
			.x = 0, .y = 0, .size = 0, .requested_size = sides[i],
		});
	}
	if (tiles.len() == 0) return LIGHTMAP_NO_ATLAS~;

	// Packed largest first, and shrunk as a whole until the atlas that holds it is
	// inside the budget. Scaling every tile by the same factor keeps the relative
	// densities the scene was measured at.
	uint side = 0;
	float scale = 1.0f;
	for (uint attempt = 0; attempt < 16 && side == 0; attempt++)
	{
		usz total = 0;
		foreach (&tile : tiles)
		{
			float at = tile.requested_size * scale;
			uint inner = (uint)math::ceil((double)at);
			if (inner < LIGHTMAP_TILE_MIN) inner = LIGHTMAP_TILE_MIN;
			if (inner > LIGHTMAP_TILE_MAX) inner = LIGHTMAP_TILE_MAX;
			tile.size = inner + 2 * LIGHTMAP_TILE_PAD;
			total += (usz)tile.size * (usz)tile.size;
		}
		lightmap_sort_tiles(tiles.array_view());
		foreach (candidate : LIGHTMAP_SIDES)
		{
			usz bytes = (usz)candidate * (usz)candidate * LIGHTMAP_TEXEL_BYTES;
			if (bytes > budget) break;
			if ((usz)candidate * (usz)candidate < total) continue;
			if (!lightmap_pack(tiles.array_view(), candidate)) continue;
			side = candidate;
			break;
		}
		if (side == 0) scale *= 0.75f;
	}
	if (side == 0) return LIGHTMAP_NO_ATLAS~;

	map.ensure_image(gpu, side)!;
	self.record_lightmap(gpu, tiles.array_view(), side, whole: true)!;

	// The tiles the copies read, written back only once the bake has landed — a
	// node pointing into an atlas the submission did not fill would draw whatever
	// was there before.
	float inv = 1.0f / (float)side;
	foreach (&tile : tiles)
	{
		uint inner = tile.size - 2 * LIGHTMAP_TILE_PAD;
		self.scene.nodes[tile.node].lightmap = {
			(float)(tile.x + LIGHTMAP_TILE_PAD) * inv,
			(float)(tile.y + LIGHTMAP_TILE_PAD) * inv,
			(float)inner * inv,
			(float)inner * inv,
		};
		tile.material_signature = self.lightmap_material_signature(&self.scene.nodes[tile.node]);
	}
	map.adopt(tiles.array_view(), self.scene.id, density * scale);
	map.live = true;
	map.signature = self.baked_light_signature();
	if (map.baked_lights.allocator == null) map.baked_lights.init(mem, self.lighting.count);
	map.baked_lights.clear();
	for (uint i = 0; i < self.lighting.count; i++) map.baked_lights.push(self.lighting.lights[i]);
	map.seen = self.scene.lightmap_changes;
	Vec3 baked_eye = self.camera.eye();
	Matrix4f baked_view_projection = self.camera.view_projection(self.aspect);
	map.camera_signature = hash_bytes(KEY_SEED, &baked_eye, Vec3::size);
	map.camera_signature = hash_bytes(map.camera_signature, &baked_view_projection, Matrix4f::size);
	self.scene.lightmap_live = true;

	usz texels = 0;
	foreach (tile : tiles) texels += (usz)tile.size * (usz)tile.size;
	double ms = (double)started.to_now() / 1_000_000.0;
	map.last = {
		.receivers = (uint)tiles.len(),
		.skipped = skipped,
		.texels = texels,
		.bytes = map.bytes(),
		.ms = ms,
	};
	return map.last;
}

// The packing, kept, so a single tile can be re-baked into the same rectangle.
fn void Lightmap.adopt(&self, LightmapTile[] tiles, uint scene, float density)
{
	if (self.tiles.allocator == null) self.tiles.init(mem, tiles.len > 0 ? tiles.len : 16);
	self.tiles.clear();
	foreach (tile : tiles) self.tiles.push(tile);
	self.scene_id = scene;
	self.density = density;
}

// Nothing is waiting to be re-baked, and nothing is waiting to be spread.
fn void Lightmap.clear_dirty(&self)
{
	self.dirty = 0;
	self.pending_count = 0;
	self.pending_all = false;
}

// Largest first, so the shelves come out even. An insertion sort: a scene's
// receivers are hundreds rather than millions, and `mergesort` here would want a
// captureless comparator over a struct the packer then rewrites.
fn void lightmap_sort_tiles(LightmapTile[] tiles) @local
{
	for (sz i = 1; i < tiles.len; i++)
	{
		LightmapTile value = tiles[i];
		sz j = i;
		while (j > 0 && tiles[j - 1].size < value.size)
		{
			tiles[j] = tiles[j - 1];
			j--;
		}
		tiles[j] = value;
	}
}

<*
 The submission: one rendering over the tiles asked for, one draw each through
 the viewport, then the readback, the seam sweep and the upload back.

 One `vkCmdBeginRendering` for every tile rather than one each: the viewport and
 the scissor are dynamic state, so a tile is two commands and a draw.

 Only the tiles named are read back, packed one after another into the staging
 buffer rather than as a window on the whole square — which is what makes a
 re-bake of four tiles cost four tiles and not thirty-two megabytes, and what
 lets `save_lightmap` write the used texels and nothing else.

 @param whole : `Whether these are all the tiles there are. True clears the atlas and treats its contents as undefined; false loads what is there and clears only the rectangles about to be redrawn.`
*>
fn void? MeshPass.record_lightmap(&self, Gpu* gpu, LightmapTile[] tiles, uint side, bool whole)
{
	Lightmap* map = &self.lightmap;
	MeshPipeline* pipeline = &map.pipeline;
	// First, so that every way out below gives the six buffers back — the two that
	// answer `LIGHTMAP_NO_ATLAS` in the middle of this included.
	defer map.free_buffers();

	// The frame the bake shades against: the same lights and the same shadow views
	// the last frame used, in buffers of the bake's own — a submission outside a
	// frame has no slot's buffer to point at.
	sz light_count = self.lighting.count > 0 ? (sz)self.lighting.count : 1;
	map.lights = gpu.create_dynamic(light_count * Light::size)!;
	map.lights.upload(&self.lighting.lights[0], light_count * Light::size);

	ulong views_address = 0;
	uint view_count = self.shadow_manager.packed_count;
	if (view_count > 0)
	{
		map.views = gpu.create_dynamic((sz)view_count * ShadowGpuView::size)!;
		map.views.upload(&self.shadow_manager.packed[0], (sz)view_count * ShadowGpuView::size);
		views_address = map.views.address;
	}

	Vec3 eye = self.camera.eye();
	FrameBlock frame = {
		.view_projection = self.frame_view_projection,
		.lighting = { self.lighting.ambient, (float)self.lighting.count, 0, 0 },
		.live_poses = null,
		.light_view_projection = matrix::IDENTITY4{float},
		.shadow = { 0, 0, 0, 0 },
		.debug = { 0, 0, 0, 0 },
		.camera = { eye.x, eye.y, eye.z, 0 },
		.environment = { 0, 0, 0, 0 },
		.lights = (Light*)map.lights.address,
		.morph_weights = null,
		.world = self.lighting.world,
		.point_shadow = { 0, 0, 0, 0 },
		.inverse_view_projection = matrix::IDENTITY4{float},
		.ambient_occlusion = { 0, 0, 0, 0 },
		.shadow_views = (ShadowGpuView*)views_address,
		// No cluster grid: the bake has no camera, so `shared_baked_diffuse` walks
		// every light rather than a cluster's list.
		.cluster_counts = null,
		.cluster_indices = null,
		.cluster_grid = { 0, 0, 0, 0 },
		.cluster_screen = { 0, 0, 0, 0 },
	};
	map.frame = gpu.create_dynamic(FrameBlock::size)!;
	map.frame.upload(&frame, FrameBlock::size);

	// One `Instance` and one `DrawRecord` per tile, all resident at submit time —
	// the command buffer is recorded whole before anything runs, so a single record
	// rewritten between draws would give every tile the last one's geometry.
	map.instances = gpu.create_dynamic((sz)tiles.len * Instance::size)!;
	map.draws = gpu.create_dynamic((sz)tiles.len * DrawRecord::size)!;
	Instance* copies = (Instance*)map.instances.data();
	DrawRecord* records = (DrawRecord*)map.draws.data();
	uint drawn = 0;
	foreach (i, tile : tiles)
	{
		Node* node = &self.scene.nodes[tile.node];
		GpuMesh* mesh = self.assets.mesh(node.asset, node.mesh);
		if (mesh == null) continue;
		Material* material = self.material(node.material);
		copies[i] = {
			.model = node.world,
			.normal = node.normal,
			.color = { 1, 1, 1, 1 },
			.variant = node.variant,
			.pose = 0,
			.lightmap = { 0, 0, 0, 0 },
		};
		records[i] = {
			.positions = (Vec3*)mesh.positions.address,
			.normals = (Vec3*)(mesh.has_normals ? mesh.normals.address : 0),
			.uvs = (Vec2*)mesh.uvs.address,
			.lightmap_uvs = (Vec2*)(mesh.lightmap_generated ? mesh.lightmap_uvs.address : mesh.uvs.address),
			.colors = (Vec4*)(mesh.has_colors ? mesh.colors.address : 0),
			.joints = null,
			.weights = null,
			.palette = null,
			.posed = null,
			.morph = null,
			.base_color = { 1, 1, 1, 1 },
			.flags = (mesh.has_normals ? FLAG_HAS_NORMALS : 0)
				| (mesh.has_uvs ? FLAG_HAS_UVS : 0)
				| (mesh.has_colors ? FLAG_HAS_COLORS : 0)
				| (mesh.colors_are_mask ? FLAG_COLORS_ARE_MASK : 0)
				| self.map_flags(material),
			.skin_stride = 0,
			.morph_targets = 0,
			.uv_transform = material.uv_transform_or_identity(),
			.surface = { 1, 0, 0, 0 },
			.uv_variant_count = material.uv_variant_count,
			.uv_variants = material.uv_variants,
			// Nothing here samples a material's maps — the bake defines drop them —
			// and the row still has to name a live slot rather than index 0, which is
			// a real image.
			.texture_index = texture_index_row(&self.assets, material, mesh),
		};
		drawn++;
	}
	if (drawn == 0) return LIGHTMAP_NO_ATLAS~;
	MeshPipeline*[] tile_pipelines = mem::new_array(MeshPipeline*, tiles.len);
	defer mem::free(tile_pipelines);
	// Compile first. The cache is a growing List, so pointers into it are only
	// taken after every push that can relocate its storage has happened.
	foreach (i, tile : tiles)
	{
		Node* node = &self.scene.nodes[tile.node];
		Material* material = self.material(node.material);
		if (material != null && material.script_layers.present)
		{
			MeshPipeline* custom = self.lightmap_pipeline_for(gpu, node.material)!;
			if (custom == null) return LIGHTMAP_NO_PIPELINE~;
		}
	}
	foreach (i, tile : tiles)
	{
		Node* node = &self.scene.nodes[tile.node];
		Material* material = self.material(node.material);
		tile_pipelines[i] = pipeline;
		if (material != null && material.script_layers.present)
		{
			tile_pipelines[i] = self.lightmap_pipeline_for(gpu, node.material)!;
		}
	}

	// Where each tile's texels land in the staging buffer, packed rather than
	// windowed: `bufferRowLength` is the tile's own width, so a tile is contiguous
	// and the seam sweep works on it as if it were an image of its own.
	vk::BufferImageCopy[] regions = mem::new_array(vk::BufferImageCopy, tiles.len);
	defer mem::free(regions);
	sz packed = 0;
	foreach (i, tile : tiles)
	{
		regions[i] = {
			.bufferOffset = (vk::DeviceSize)packed,
			.bufferRowLength = tile.size,
			.bufferImageHeight = tile.size,
			.imageSubresource = { .aspectMask = IMAGE_ASPECT_COLOR_BIT, .mipLevel = 0, .baseArrayLayer = 0,
				.layerCount = 1 },
			.imageOffset = { (int)tile.x, (int)tile.y, 0 },
			.imageExtent = { tile.size, tile.size, 1 },
		};
		packed += (sz)tile.size * (sz)tile.size * (sz)LIGHTMAP_TEXEL_BYTES;
	}

	map.staging = vk::new_buffer(
		&gpu.allocator,
		usage: BUFFER_USAGE_TRANSFER_DST_BIT | BUFFER_USAGE_TRANSFER_SRC_BIT,
		properties: MEMORY_PROPERTY_HOST_VISIBLE_BIT | MEMORY_PROPERTY_HOST_COHERENT_BIT,
		data_size: packed,
	)!;

	self.shadow_manager.atlas.ensure_compare(gpu)!;
	gpu.handle.@single_time_command(queue: gpu.graphics ; vk::CommandBuffer cmd)
	{
		self.shadow_manager.atlas.record_blank(cmd);
		vk::ImageMemoryBarrier2 to_attachment = {
			...IMAGE_BARRIER, .image = map.image,
			.srcStageMask = PIPELINE_STAGE_2_ALL_COMMANDS_BIT,
			.srcAccessMask = (vk::AccessFlags2)0,
			.dstStageMask = PIPELINE_STAGE_2_COLOR_ATTACHMENT_OUTPUT_BIT,
			.dstAccessMask = ACCESS_2_COLOR_ATTACHMENT_WRITE_BIT,
			// A partial bake keeps what the tiles it is not touching hold, so the old
			// layout is the one the last upload left rather than the discard a fresh
			// atlas wants.
			.oldLayout = whole ? IMAGE_LAYOUT_UNDEFINED : IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
			.newLayout = IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
			.subresourceRange = COLOR_LEVEL,
		};
		vk::cmdPipelineBarrier2(cmd, &&vk::dependencyInfo().setImageMemoryBarriers({ to_attachment }));

		vk::RenderingAttachmentInfo colour = vk::renderingAttachmentInfo().setImageView(map.view)
			.setImageLayout(IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL)
			.setLoadOp(whole ? ATTACHMENT_LOAD_OP_CLEAR : ATTACHMENT_LOAD_OP_LOAD)
			.setStoreOp(ATTACHMENT_STORE_OP_STORE)
			.setClearValue({ .color = { .float32 = { 0, 0, 0, 0 } } });
		vk::Rect2D area = { .offset = { 0, 0 }, .extent = { side, side } };
		vk::RenderingInfo rendering = vk::renderingInfo().setRenderArea(area).setLayerCount(1)
			.setColorAttachments({ colour });
		vk::cmdBeginRendering(cmd, &rendering);

		vk::cmdBindPipeline(cmd, PIPELINE_BIND_POINT_GRAPHICS, pipeline.handle);
		gpu.texture_table.bind(cmd, pipeline.layout);

		SampledBindings samplers;
		// Whatever the linked program kept. Under the bake defines almost every
		// sampler is dropped — nothing reads a colour — and pushing a write for a
		// binding the layout does not declare is a validation error.
		foreach (declared : pipeline.shader.bindings)
		{
			if (declared.set != 0) continue;
			if (declared.type != DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER) continue;
			if (declared.binding == SHADOW_ATLAS_COMPARE_BINDING
				|| declared.binding == SHADOW_ATLAS_STATIC_COMPARE_BINDING) continue;
			samplers.add(declared.binding, self.assets.texture_at(NO_TEXTURE).descriptor());
		}
		if (pipeline_declares_binding(pipeline, SHADOW_ATLAS_COMPARE_BINDING))
		{
			samplers.add(SHADOW_ATLAS_COMPARE_BINDING, self.shadow_manager.atlas.compare_descriptor(
				true, self.shadow_manager.atlas.static_initialized));
		}
		if (pipeline_declares_binding(pipeline, SHADOW_ATLAS_STATIC_COMPARE_BINDING))
		{
			samplers.add(SHADOW_ATLAS_STATIC_COMPARE_BINDING,
				self.shadow_manager.atlas.compare_descriptor(
					true, self.shadow_manager.atlas.static_initialized));
		}
		samplers.push(cmd, pipeline);

		// A tile the rendering loaded rather than cleared holds the last bake, margin
		// and all, and the sweep below reads the alpha to decide which texels a
		// triangle covered. Cleared here, whole rectangle, so it reads the same as a
		// tile in a fresh atlas.
		if (!whole)
		{
			vk::ClearAttachment blank = {
				.aspectMask = IMAGE_ASPECT_COLOR_BIT,
				.colorAttachment = 0,
				.clearValue = { .color = { .float32 = { 0, 0, 0, 0 } } },
			};
			vk::ClearRect[] blanks = mem::new_array(vk::ClearRect, tiles.len);
			defer mem::free(blanks);
			foreach (i, tile : tiles)
			{
				blanks[i] = {
					.rect = { .offset = { (int)tile.x, (int)tile.y },
						.extent = { tile.size, tile.size } },
					.baseArrayLayer = 0,
					.layerCount = 1,
				};
			}
			vk::cmdClearAttachments(cmd, 1, &blank, (uint)blanks.len, blanks.ptr);
		}

		foreach (i, tile : tiles)
		{
			Node* node = &self.scene.nodes[tile.node];
			GpuMesh* mesh = self.assets.mesh(node.asset, node.mesh);
			if (mesh == null) continue;
			// The rendered part of the tile, one texel in from its rectangle on every
			// side. Unflipped, because uv (0,0) is the top-left texel of an image and
			// every other pass in the project flips Y to put the world the right way up.
			vk::Rect2D rect = {
				.offset = { (int)(tile.x + LIGHTMAP_TILE_PAD), (int)(tile.y + LIGHTMAP_TILE_PAD) },
				.extent = { tile.size - 2 * LIGHTMAP_TILE_PAD, tile.size - 2 * LIGHTMAP_TILE_PAD },
			};
			set_viewport_rect(cmd, rect, false);

			MeshPipeline* selected = tile_pipelines[i];
			vk::cmdBindPipeline(cmd, PIPELINE_BIND_POINT_GRAPHICS, selected.handle);
			gpu.texture_table.bind(cmd, selected.layout);
			SampledBindings selected_samplers;
			foreach (declared : selected.shader.bindings)
			{
				if (declared.set != 0 || declared.type != DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER) continue;
				if (declared.binding == SHADOW_ATLAS_COMPARE_BINDING
					|| declared.binding == SHADOW_ATLAS_STATIC_COMPARE_BINDING) continue;
				selected_samplers.add(declared.binding, self.assets.texture_at(NO_TEXTURE).descriptor());
			}
			if (pipeline_declares_binding(selected, SHADOW_ATLAS_COMPARE_BINDING))
			{
				selected_samplers.add(SHADOW_ATLAS_COMPARE_BINDING,
					self.shadow_manager.atlas.compare_descriptor(
						true, self.shadow_manager.atlas.static_initialized));
			}
			if (pipeline_declares_binding(selected, SHADOW_ATLAS_STATIC_COMPARE_BINDING))
			{
				selected_samplers.add(SHADOW_ATLAS_STATIC_COMPARE_BINDING,
					self.shadow_manager.atlas.compare_descriptor(
						true, self.shadow_manager.atlas.static_initialized));
			}
			selected_samplers.push(cmd, selected);
			MeshPush push = {
				.frame = (FrameBlock*)map.frame.address,
				.instances = (Instance*)(map.instances.address + (ulong)i * Instance::size),
				.draw = (DrawRecord*)(map.draws.address + (ulong)i * DrawRecord::size),
			};
			char[PUSH_BUDGET] pushed = {};
			mem::copy(&pushed, &push, MeshPush::size);
			Material* material = self.material(node.material);
			uint push_size = selected.shader.push_size;
			if (material != null && push_size > MATERIAL_PUSH_START)
			{
				mem::copy(&pushed[MATERIAL_PUSH_START], &material.block[MATERIAL_PUSH_START],
					(sz)(push_size - MATERIAL_PUSH_START));
				if (material.table_pointer != NO_TABLE_POINTER && self.table_address != 0)
				{
					ulong table = self.table_address + (ulong)material.table_offset;
					mem::copy(&pushed[material.table_pointer], &table, ulong::size);
				}
			}
			vk::cmdPushConstants(cmd, selected.layout, selected.shader.stages, 0, push_size, &pushed);
			vk::cmdBindIndexBuffer(cmd, mesh.indices.buffer, 0, INDEX_TYPE_UINT32);
			vk::cmdDrawIndexed(cmd, mesh.index_count, 1, 0, 0, 0);
		}

		vk::cmdEndRendering(cmd);

		vk::ImageMemoryBarrier2 to_source = {
			...IMAGE_BARRIER, .image = map.image,
			.srcStageMask = PIPELINE_STAGE_2_COLOR_ATTACHMENT_OUTPUT_BIT,
			.srcAccessMask = ACCESS_2_COLOR_ATTACHMENT_WRITE_BIT,
			.dstStageMask = PIPELINE_STAGE_2_ALL_TRANSFER_BIT,
			.dstAccessMask = ACCESS_2_TRANSFER_READ_BIT,
			.oldLayout = IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
			.newLayout = IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
			.subresourceRange = COLOR_LEVEL,
		};
		vk::cmdPipelineBarrier2(cmd, &&vk::dependencyInfo().setImageMemoryBarriers({ to_source }));
		vk::cmdCopyImageToBuffer(cmd, map.image, IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, map.staging.buffer,
			(uint)regions.len, regions.ptr);
	}!;

	// The seams, on the CPU and in the atlas's own bytes. Host-coherent, and the
	// single-time command has already waited.
	char[] texels = ((char*)map.staging.data())[:packed];
	uint widest = 0;
	foreach (tile : tiles) if (tile.size > widest) widest = tile.size;
	uint[] spread = mem::new_array(uint, (sz)widest * (sz)widest);
	defer mem::free(spread);
	foreach (i, tile : tiles)
	{
		sz at = (sz)regions[i].bufferOffset;
		sz bytes = (sz)tile.size * (sz)tile.size * (sz)LIGHTMAP_TEXEL_BYTES;
		// Tile-local: packed, the rectangle is the whole of its own little image.
		lightmap_dilate(texels[at:bytes], tile.size, { .x = 0, .y = 0, .size = tile.size }, spread);
	}

	gpu.handle.@single_time_command(queue: gpu.graphics ; vk::CommandBuffer cmd)
	{
		vk::ImageMemoryBarrier2 to_destination = {
			...IMAGE_BARRIER, .image = map.image,
			.srcStageMask = PIPELINE_STAGE_2_ALL_TRANSFER_BIT,
			.srcAccessMask = ACCESS_2_TRANSFER_READ_BIT,
			.dstStageMask = PIPELINE_STAGE_2_ALL_TRANSFER_BIT,
			.dstAccessMask = ACCESS_2_TRANSFER_WRITE_BIT,
			.oldLayout = IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
			.newLayout = IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
			.subresourceRange = COLOR_LEVEL,
		};
		vk::cmdPipelineBarrier2(cmd, &&vk::dependencyInfo().setImageMemoryBarriers({ to_destination }));
		vk::cmdCopyBufferToImage(cmd, map.staging.buffer, map.image, IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
			(uint)regions.len, regions.ptr);
		vk::ImageMemoryBarrier2 to_shader = {
			...IMAGE_BARRIER, .image = map.image,
			.srcStageMask = PIPELINE_STAGE_2_ALL_TRANSFER_BIT,
			.srcAccessMask = ACCESS_2_TRANSFER_WRITE_BIT,
			.dstStageMask = PIPELINE_STAGE_2_FRAGMENT_SHADER_BIT,
			.dstAccessMask = ACCESS_2_SHADER_SAMPLED_READ_BIT,
			.oldLayout = IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
			.newLayout = IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
			.subresourceRange = COLOR_LEVEL,
		};
		vk::cmdPipelineBarrier2(cmd, &&vk::dependencyInfo().setImageMemoryBarriers({ to_shader }));
	}!;
	map.revision++;
}

// ============================================================================
// The file
// ============================================================================

<*
 The engine's own format, because there is no other one to use.

 `.ktx2` is what this project already writes for textures, and it writes it
 through the Basis/BC7 encoder — a block format for colour, which an RGBA16F
 lightmap is not, and a container that has nowhere to put the tile table anyway.
 So: a header, one record per tile, and the tiles' texels packed one after
 another. The empty three quarters of an atlas are not written at all, which on
 FF9 is the difference between 32 MB and nine.

 A receiver is named by its node's name, its mesh index, and which copy of that
 pair it is in slot order. A slot index would name a different node in a scene
 built in a different order, and the two hundred crates in a level share a name
 and a mesh between them.
*>
// Where `three.lights.saveBake()` writes when a script names no path.
const String LIGHTMAP_DEFAULT_PATH = "bake.lightmap";

const char[8] LIGHTMAP_MAGIC = { '3', 'L', 'I', 'G', 'H', 'T', 'M' , 'P' };
const uint LIGHTMAP_FILE_VERSION = 6;

// Laid out so that nothing is padded: eight bytes, then six fours, then two
// eights. A file is written and read by the same struct, and a hole in the
// middle of it would be whatever the stack last held.
struct LightmapHeader
{
	char[8] magic;
	uint version;
	uint side;
	// `LIGHTMAP_FORMAT` as the device spells it, so a build that changed the
	// atlas format refuses an old file rather than reading it as this one.
	uint format;
	uint tiles;
	// The baked light set the atlas is a sum over. A file whose signature is not
	// this scene's is a bake of a different lighting and is refused.
	uint signature;
	float density;
	ulong camera_signature;
	// FNV-1a over everything after this header — the records and the texels.
	ulong hash;
	ulong texel_bytes;
}

struct LightmapFileTile
{
	ulong name;
	// The node's world matrix, folded. What decides whether this tile loads clean
	// or loads and joins the dirty list.
	ulong world;
	uint mesh;
	uint copy;
	uint x;
	uint y;
	uint size;
	float density;
	ulong material_signature;
}

// What one copy is called, for a file that has to find it again in a scene the
// engine built from the same asset a second time.
struct LightmapIdentity
{
	ulong name;
	uint mesh;
	uint copy;
}

struct LightmapFileResult
{
	uint tiles;
	uint dirty;
	usz bytes;
	double ms;
}

fn ulong lightmap_name_hash(String name) => hash_bytes(KEY_SEED, name.ptr, name.len);

// The identity of every node in the scene, by slot. Answered for the whole pool
// rather than for the receivers, because the copy index counts *nodes* — an
// eligibility test that changed between a save and a load must not renumber the
// copies that are still there.
fn LightmapIdentity[] MeshPass.lightmap_identities(&self, alloc::Allocator allocator)
{
	LightmapIdentity[] named = alloc::new_array(allocator, LightmapIdentity, self.scene.nodes.len());
	foreach (slot, &node : self.scene.nodes)
	{
		named[slot] = { .name = 0, .mesh = NO_MESH, .copy = 0 };
		if (!node.alive || !node.asset.is_set() || node.mesh == NO_MESH) continue;
		ulong name = lightmap_name_hash(node.name);
		uint copy = 0;
		for (sz i = 0; i < slot; i++)
		{
			if (named[i].name == name && named[i].mesh == node.mesh) copy++;
		}
		named[slot] = { .name = name, .mesh = node.mesh, .copy = copy };
	}
	return named;
}

fn ulong lightmap_world_hash(Matrix4f world) => hash_bytes(KEY_SEED, &world, Matrix4f::size);

// The tile regions in the atlas, packed one after another in the buffer — the
// layout the readback, the upload and the file all share.
fn usz lightmap_regions(LightmapTile[] tiles, vk::BufferImageCopy[] into)
{
	usz packed = 0;
	foreach (i, tile : tiles)
	{
		into[i] = {
			.bufferOffset = (vk::DeviceSize)packed,
			.bufferRowLength = tile.size,
			.bufferImageHeight = tile.size,
			.imageSubresource = { .aspectMask = IMAGE_ASPECT_COLOR_BIT, .mipLevel = 0, .baseArrayLayer = 0,
				.layerCount = 1 },
			.imageOffset = { (int)tile.x, (int)tile.y, 0 },
			.imageExtent = { tile.size, tile.size, 1 },
		};
		packed += (usz)tile.size * (usz)tile.size * (usz)LIGHTMAP_TEXEL_BYTES;
	}
	return packed;
}

// The atlas's tiles, off the device and into host memory, packed.
fn void? Lightmap.read_tiles(&self, Gpu* gpu, LightmapTile[] tiles, char[] into)
{
	@pool()
	{
		vk::BufferImageCopy[] regions = alloc::new_array(tmem, vk::BufferImageCopy, tiles.len);
		usz packed = lightmap_regions(tiles, regions);
		if (packed > into.len) return LIGHTMAP_NO_ATLAS~;

		vk::Memory staging = vk::new_buffer(
			&gpu.allocator,
			usage: BUFFER_USAGE_TRANSFER_DST_BIT,
			properties: MEMORY_PROPERTY_HOST_VISIBLE_BIT | MEMORY_PROPERTY_HOST_COHERENT_BIT,
			data_size: (sz)packed,
		)!;
		defer staging.free();

		gpu.handle.@single_time_command(queue: gpu.graphics ; vk::CommandBuffer cmd)
		{
			self.transition(cmd, IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL, IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL);
			vk::cmdCopyImageToBuffer(cmd, self.image, IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, staging.buffer,
				(uint)regions.len, regions.ptr);
			self.transition(cmd, IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL);
		}!;
		mem::copy(into.ptr, staging.data(), (sz)packed);
	};
}

// The same journey the other way: host bytes into the tiles of a fresh atlas.
fn void? Lightmap.write_tiles(&self, Gpu* gpu, LightmapTile[] tiles, char[] from)
{
	@pool()
	{
		vk::BufferImageCopy[] regions = alloc::new_array(tmem, vk::BufferImageCopy, tiles.len);
		usz packed = lightmap_regions(tiles, regions);
		if (packed > from.len) return LIGHTMAP_BAD_FILE~;

		vk::Memory staging = vk::new_buffer(
			&gpu.allocator,
			usage: BUFFER_USAGE_TRANSFER_SRC_BIT,
			properties: MEMORY_PROPERTY_HOST_VISIBLE_BIT | MEMORY_PROPERTY_HOST_COHERENT_BIT,
			data_size: (sz)packed,
		)!;
		defer staging.free();
		mem::copy(staging.data(), from.ptr, (sz)packed);

		gpu.handle.@single_time_command(queue: gpu.graphics ; vk::CommandBuffer cmd)
		{
			// Undefined rather than the shader layout: every texel a copy does not
			// write is one nothing reads, so there is nothing to preserve.
			self.transition(cmd, IMAGE_LAYOUT_UNDEFINED, IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL);
			vk::cmdCopyBufferToImage(cmd, staging.buffer, self.image, IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
				(uint)regions.len, regions.ptr);
			self.transition(cmd, IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL);
		}!;
	};
}

fn void Lightmap.transition(&self, vk::CommandBuffer cmd, vk::ImageLayout from, vk::ImageLayout to)
{
	vk::ImageMemoryBarrier2 barrier = {
		...IMAGE_BARRIER, .image = self.image,
		.srcStageMask = PIPELINE_STAGE_2_ALL_COMMANDS_BIT,
		.srcAccessMask = ACCESS_2_MEMORY_WRITE_BIT,
		.dstStageMask = PIPELINE_STAGE_2_ALL_COMMANDS_BIT,
		.dstAccessMask = ACCESS_2_MEMORY_READ_BIT | ACCESS_2_MEMORY_WRITE_BIT,
		.oldLayout = from,
		.newLayout = to,
		.subresourceRange = COLOR_LEVEL,
	};
	vk::cmdPipelineBarrier2(cmd, &&vk::dependencyInfo().setImageMemoryBarriers({ barrier }));
}

<*
 Writes the atlas and its tile table to `path`.

 @return ? LIGHTMAP_NO_DEVICE : `No GPU to read the atlas off.`
 @return ? LIGHTMAP_NO_ATLAS : `Nothing has been baked, or the bake belongs to another scene.`
*>
fn LightmapFileResult? MeshPass.save_lightmap(&self, String path)
{
	Gpu* gpu = self.assets.gpu;
	if (gpu == null || gpu.handle == null) return LIGHTMAP_NO_DEVICE~;
	Lightmap* map = &self.lightmap;
	if (self.scene == null || !map.live || map.image == null || map.tiles.len() == 0)
	{
		return LIGHTMAP_NO_ATLAS~;
	}
	if (map.scene_id != self.scene.id) return LIGHTMAP_NO_ATLAS~;

	Clock started = clock::now();
	// The world matrices are what a tile is stamped with, so a transform a script
	// wrote and nothing has walked yet has to be resolved before it is folded.
	self.scene.update_world_matrices();
	LightmapTile[] tiles = map.tiles.array_view();
	usz texel_bytes = 0;
	foreach (tile : tiles) texel_bytes += (usz)tile.size * (usz)tile.size * (usz)LIGHTMAP_TEXEL_BYTES;

	usz records = (usz)tiles.len * LightmapFileTile::size;
	usz total = LightmapHeader::size + records + texel_bytes;
	char[] file = mem::new_array(char, (sz)total);
	defer mem::free(file);

	@pool()
	{
		LightmapIdentity[] named = self.lightmap_identities(tmem);
		LightmapFileTile* out = (LightmapFileTile*)&file[LightmapHeader::size];
		foreach (i, tile : tiles)
		{
			Node* node = &self.scene.nodes[tile.node];
			LightmapIdentity who = named[tile.node];
			out[i] = {
				.name = who.name,
				.world = lightmap_world_hash(node.world),
				.mesh = who.mesh,
				.copy = who.copy,
				.x = tile.x,
				.y = tile.y,
				.size = tile.size,
				.density = map.density,
				.material_signature = tile.material_signature,
			};
		}
	};

	map.read_tiles(gpu, tiles, file[(LightmapHeader::size + records)..])!;

	LightmapHeader* header = (LightmapHeader*)file.ptr;
	*header = {
		.magic = LIGHTMAP_MAGIC,
		.version = LIGHTMAP_FILE_VERSION,
		.side = map.side,
		.format = (uint)LIGHTMAP_FORMAT,
		.tiles = (uint)tiles.len,
		.signature = map.signature,
		.density = map.density,
		.camera_signature = map.camera_signature,
		.hash = hash_bytes(KEY_SEED, &file[LightmapHeader::size], total - LightmapHeader::size),
		.texel_bytes = texel_bytes,
	};
	file::save(path, file)!;
	return {
		.tiles = (uint)tiles.len,
		.dirty = map.dirty,
		.bytes = total,
		.ms = (double)started.to_now() / 1_000_000.0,
	};
}

<*
 Reads a saved atlas back, and marks the receivers that have moved since.

 The bake this replaces is the whole of a shipped game's boot stall. What it
 checks before it believes the file: the magic, the version, the atlas format, a
 hash over the payload, the set of baked lights, and then the receivers themselves
 — every eligible copy in the scene now must be one the file has a tile for, and
 there must be no tiles left over. Anything else is a bake of a different scene
 and the caller falls back to making a new one.

 A receiver the file has at a different world matrix keeps its rectangle and joins
 the dirty list, so the load covers what has not moved and the budget covers what
 has.

 @return ? LIGHTMAP_NO_DEVICE : `No GPU to put the atlas on.`
 @return ? LIGHTMAP_NO_ATLAS : `No scene, or the atlas would not fit.`
 @return ? LIGHTMAP_NO_PIPELINE : `The bake shader would not compile, so the dirty tiles have nothing to run on.`
 @return ? LIGHTMAP_BAD_FILE : `Not a lightmap, a newer one, or damaged.`
 @return ? LIGHTMAP_STALE : `A bake of other lights, or of other receivers.`
*>
fn LightmapFileResult? MeshPass.load_lightmap(&self, String path)
{
	Gpu* gpu = self.assets.gpu;
	if (gpu == null || gpu.handle == null) return LIGHTMAP_NO_DEVICE~;
	if (self.scene == null) return LIGHTMAP_NO_ATLAS~;

	Clock started = clock::now();
	self.scene.update_world_matrices();
	char[]? read = file::load(mem, path);
	if (catch read) return LIGHTMAP_BAD_FILE~;
	char[] file = read;
	defer mem::free(file);

	if (file.len < LightmapHeader::size) return LIGHTMAP_BAD_FILE~;
	LightmapHeader header = *(LightmapHeader*)file.ptr;
	if (header.magic != LIGHTMAP_MAGIC) return LIGHTMAP_BAD_FILE~;
	if (header.version != LIGHTMAP_FILE_VERSION) return LIGHTMAP_BAD_FILE~;
	if (header.format != (uint)LIGHTMAP_FORMAT) return LIGHTMAP_BAD_FILE~;
	if (header.tiles == 0 || header.side == 0) return LIGHTMAP_BAD_FILE~;
	Vec3 load_eye = self.camera.eye();
	Matrix4f load_view_projection = self.camera.view_projection(self.aspect);
	ulong load_camera = hash_bytes(KEY_SEED, &load_eye, Vec3::size);
	load_camera = hash_bytes(load_camera, &load_view_projection, Matrix4f::size);
	if (header.camera_signature != load_camera) return LIGHTMAP_STALE~;
	usz records = (usz)header.tiles * LightmapFileTile::size;
	usz total = LightmapHeader::size + records + (usz)header.texel_bytes;
	if (file.len != total) return LIGHTMAP_BAD_FILE~;
	if (hash_bytes(KEY_SEED, &file[LightmapHeader::size], total - LightmapHeader::size) != header.hash)
	{
		return LIGHTMAP_BAD_FILE~;
	}
	if (header.signature != self.baked_light_signature()) return LIGHTMAP_STALE~;

	LightmapFileTile* saved = (LightmapFileTile*)&file[LightmapHeader::size];
	Lightmap* map = &self.lightmap;
	uint dirty = 0;

	@pool()
	{
		LightmapIdentity[] named = self.lightmap_identities(tmem);
		// The receivers this scene has now, in slot order and by the same test the
		// bake uses — see `MeshPass.lightmap_receivers`.
		uint[] slots = alloc::new_array(tmem, uint, self.scene.nodes.len());
		uint count = self.lightmap_receivers(slots, (float[]){ });
		if (count != header.tiles) return LIGHTMAP_STALE~;

		LightmapTile[] tiles = alloc::new_array(tmem, LightmapTile, count);
		bool[] moved = alloc::new_array(tmem, bool, count);
		for (uint i = 0; i < count; i++)
		{
			Node* node = &self.scene.nodes[slots[i]];
			LightmapIdentity who = named[slots[i]];
			sz found = -1;
			for (uint j = 0; j < header.tiles; j++)
			{
				if (saved[j].name != who.name || saved[j].mesh != who.mesh) continue;
				if (saved[j].copy != who.copy) continue;
				found = (sz)j;
				break;
			}
			if (found < 0) return LIGHTMAP_STALE~;
			tiles[i] = {
				.node = slots[i],
				.generation = node.generation,
				.x = saved[found].x,
				.y = saved[found].y,
				.size = saved[found].size,
				.material_signature = self.lightmap_material_signature(node),
			};
			moved[i] = saved[found].world != lightmap_world_hash(node.world)
				|| saved[found].material_signature != tiles[i].material_signature;
			if (moved[i]) dirty++;
		}

		// Nothing is read through a rectangle until every one of them has landed.
		foreach (&node : self.scene.nodes)
		{
			node.lightmap = { 0, 0, 0, 0 };
			node.lightmap_dirty = false;
			node.lightmap_seed = false;
		}
		map.clear_dirty();
		map.live = false;
		self.scene.lightmap_live = false;

		map.ensure_image(gpu, header.side)!;
		// The file's tiles, in the file's own order, so its texel blocks line up.
		LightmapTile[] laid = alloc::new_array(tmem, LightmapTile, header.tiles);
		for (uint j = 0; j < header.tiles; j++)
		{
			laid[j] = { .node = 0, .generation = 0, .x = saved[j].x, .y = saved[j].y, .size = saved[j].size };
		}
		map.write_tiles(gpu, laid, file[(LightmapHeader::size + records)..])!;

		float inv = 1.0f / (float)header.side;
		for (uint i = 0; i < count; i++)
		{
			uint inner = tiles[i].size - 2 * LIGHTMAP_TILE_PAD;
			Node* node = &self.scene.nodes[tiles[i].node];
			node.lightmap = moved[i] ? (float[4]){ 0, 0, 0, 0 } : (float[4]){
				(float)(tiles[i].x + LIGHTMAP_TILE_PAD) * inv,
				(float)(tiles[i].y + LIGHTMAP_TILE_PAD) * inv,
				(float)inner * inv,
				(float)inner * inv,
			};
			node.lightmap_dirty = moved[i];
		}
		map.adopt(tiles, self.scene.id, header.density);
	};

	map.live = true;
	map.revision++;
	map.signature = header.signature;
	if (map.baked_lights.allocator == null) map.baked_lights.init(mem, self.lighting.count);
	map.baked_lights.clear();
	for (uint i = 0; i < self.lighting.count; i++) map.baked_lights.push(self.lighting.lights[i]);
	map.camera_signature = header.camera_signature;
	map.dirty = dirty;
	map.seen = self.scene.lightmap_changes;
	map.settle = 1;
	self.scene.lightmap_dirty_all = false;
	self.scene.lightmap_live = true;
	// The catch-up needs the bake pipeline, and a file that loaded onto a device
	// whose shader will not compile is still a picture. Asked for here so the
	// first dirty tile does not pay for it inside the budget.
	if (dirty > 0)
	{
		if (catch self.lightmap.ensure_pipeline(gpu)) { }
	}
	map.last = {
		.receivers = (uint)map.tiles.len(),
		.skipped = map.last.skipped,
		.texels = (usz)header.texel_bytes / LIGHTMAP_TEXEL_BYTES,
		.bytes = map.bytes(),
		.ms = (double)started.to_now() / 1_000_000.0,
	};
	return {
		.tiles = (uint)map.tiles.len(),
		.dirty = dirty,
		.bytes = total,
		.ms = map.last.ms,
	};
}
