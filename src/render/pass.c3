<*
 The mesh pass: update the scene, upload the instance table, bind, push, draw.

 ## One instanced draw per bucket, and no other path

	scene.update      world matrices, cull, sort, write Instance records
	upload            the frame block and the instance array, this slot's copies
	per bucket        bind the material's pipeline if it changed, push the
	                  texture, push the block, vkCmdDrawIndexed(N)

 There is no single-instance shortcut. A lone mesh is a bucket of one, drawn by
 the same call with an instance count of one, reading its transform out of the
 same array — which is what makes every scene the API can express optimised *by
 construction* rather than aspirationally. There is nothing to notice and nothing
 to fall out of.

 ## The instance buffer is per frame slot

 Anything the GPU may still be reading must be double-buffered, and this is the
 file that has to obey it. Each slot owns its own array and is only written after
 its fence has been waited on. Growth frees and reallocates *that slot's* buffer
 only, which is safe for the same reason writing it is.
*>
module three;

import std::io;
import std::math;
import std::math::vector;
import std::math::matrix;
import std::collections::list;
import vk;
import collision;

// The instance array starts here and doubles. Small enough that a triangle costs
// nothing, large enough that a normal scene never reallocates.
const sz INITIAL_INSTANCES = 64;

<*
 The light a renderer starts on: down and to the right, from slightly in front,
 with a quarter of the surface's colour reaching the shadowed side.

 Named rather than written twice for `DEFAULT_CLEAR`'s reason — it is something a
 script can ask to be restored to, and two spellings of a default drift.

 Not normalized here. The shaders normalize on read, so the magnitude of the
 direction has never meant anything, and normalizing at the door would make
 `three.light.direction` answer with numbers a script did not write.
*>
const float[4] DEFAULT_LIGHT = { 0.35, 0.80, 0.45, 0.25 };

<*
 The debug views `three.debug.view` selects, as `shaders/mesh.slang` reads them
 out of `FrameBlock.debug.x`.

 Numbers and not an enum because they cross into a shader as a float, and the one
 place that maps a name to one of them is `src/js/prelude/api.js`.
*>
const uint DEBUG_VIEW_OFF = 0;
// `shadow_factor` as greyscale: white lit, black fully shadowed.
const uint DEBUG_VIEW_SHADOW = 1;
// What the shadow lookup would read, with magenta for "outside the fitted box"
// and dark purple for "no shadow pass ran".
const uint DEBUG_VIEW_SHADOW_MAP = 2;
// The highest view there is, so the binding can range-check without listing them.
const uint DEBUG_VIEW_MAX = DEBUG_VIEW_SHADOW_MAP;

struct MeshPass
{
	// Compiled on demand and kept by content hash. `pipeline` is borrowed from it
	// — the cache owns every pipeline it hands out and frees them all.
	PipelineCache pipelines;
	MeshPipeline* pipeline;
	// The same shader over `LINE_STATE`. `LINE_MATERIAL` is the index that reaches
	// it, and this is the pointer that index resolves to.
	MeshPipeline* line_pipeline;
	// The same shader again, over `ALPHA_STATE` and `ADDITIVE_STATE`. These are
	// what a `three.MeshLambertMaterial` with `transparent: true` draws with.
	//
	// Held here rather than acquired when one is asked for, and that is a design
	// decision rather than an optimisation: `create_texture_material` promises
	// that putting a picture on a box needs no device, no Slang and no new
	// pipeline, and a lazily-acquired variant would break all three the first time
	// a script wrote `transparent: true`. Building them here costs one
	// `VkPipeline` each — about a millisecond, no Slang at all, since `acquire`
	// keys the compile on the source and this is the same `mesh.slang` byte for
	// byte — and it happens once at startup.
	MeshPipeline* alpha_pipeline;
	MeshPipeline* additive_pipeline;
	// Every material any node can name. Index 0 is `DEFAULT_MATERIAL`, built in
	// `init` from `pipeline`, so a scene that never mentions a material still has
	// one. Lives here rather than on `JsRuntime` for the same reason `assets` does:
	// `new three.Scene()` resets the graph, and a material an agent compiled should
	// survive that exactly as a loaded `.glb` does.
	List{Material} materials;
	Assets assets;
	<*
	 The scene being rendered, and every scene that exists.

	 One is drawn, culled, queried and stepped; the rest are worlds a script has
	 built and is holding on to — the next level, a sandbox. `new three.Scene()`
	 makes one and activates it and does *not* free the one it replaced, which is
	 Three.js's meaning and is why `SceneStats.scenes` and `note_scene_created`
	 exist: the cost of the ones nobody is looking at has to be visible.

	 Pointers, and each scene is its own allocation, because `arg_handle` hands a
	 `Scene*` to every verb that names a node and a `List` that reallocated on its
	 next push would leave those pointing into freed memory.
	*>
	Scene* scene;
	List{Scene*} scenes;
	// The scene `init` built, until a script's first `new three.Scene()` takes it
	// over — see `claim_scene`. Null afterwards, and null in a process where the
	// command line put something in it.
	Scene* bootstrap;
	Camera camera;
	// What the camera is tracking, if anything — `scene/camera.c3`. Beside the
	// camera rather than on the runtime, because it names a `NodeId` and the scene
	// those are indices into is the one on this struct; a follow held somewhere
	// else would be a handle into a graph it could not see get reset.
	CameraFollow follow;
	// The game clock — `scene/clock.c3`. Here rather than on the runtime for the
	// reason the follow is: the runtime advances it, and the *renderer* reads it
	// while recording a post chain, with no runtime to ask.
	GameClock clock;
	// The render target's width over its height, kept current by `record`.
	// `frame_camera` needs it and has no target to ask — it is reached from a
	// script, between frames — and fitting a 16:9 frame as though it were square is
	// most of why `frameAll` would otherwise leave the subject at a third of the
	// width. Seeded in `init` so the very first fit is already right.
	float aspect;
	// xyz: surface-to-light in world space. w: the ambient floor, which keeps unlit
	// faces readable rather than black.
	float[4] light;
	// How many materials have had their handle given back and are still named by a
	// node. Nonzero is the only thing that makes `record` walk the scene for
	// collectible materials, so the sweep costs nothing in the common case.
	uint pending_materials;
	// How many slots in the table above are live, not counting the two built-in
	// ones, which are nobody's to dispose. What `stats().materials` reports and
	// what `MATERIAL_WARN_AT` watches.
	uint live_materials;
	// The count the next warning is waiting for, doubling each time one fires —
	// see `note_material_claimed`.
	uint material_warn_at;
	// The same again for scenes — see `note_scene_created`.
	uint scene_warn_at;

	// Per frame in flight — see the header.
	vk::Memory[MAX_FRAMES_IN_FLIGHT] frame_blocks;
	vk::Memory[MAX_FRAMES_IN_FLIGHT] instance_buffers;
	sz[MAX_FRAMES_IN_FLIGHT] instance_capacity;
	// One `DrawRecord` per bucket, for the same reason and with the same lifetime
	// as the instance array beside it: written by the CPU during recording, read by
	// the GPU when the frame runs, and safe to overwrite only once this slot's
	// fence has been waited on.
	vk::Memory[MAX_FRAMES_IN_FLIGHT] draw_buffers;
	sz[MAX_FRAMES_IN_FLIGHT] draw_capacity;
	// Every spilled material's uniform table, end to end, for one frame in flight —
	// see `Material.table` and `write_tables`. Per slot for the instance array's
	// reason: a script writing a uniform between frames must not reach a buffer the
	// GPU is still reading.
	//
	// Zero bytes for a scene with no spilled material, which is every scene until
	// one declares more uniforms than the push block holds.
	vk::Memory[MAX_FRAMES_IN_FLIGHT] table_buffers;
	sz[MAX_FRAMES_IN_FLIGHT] table_capacity;
	// This frame's joint matrices for the characters posed from their bone nodes
	// rather than from a baked clip — `skeleton: true`. Per frame in flight for the
	// same reason as the two above, and this is the one the rule was written about:
	// a host-visible palette rewritten while the GPU is still reading it tears.
	//
	// Empty in every scene with no live character in it.
	vk::Memory[MAX_FRAMES_IN_FLIGHT] pose_buffers;
	sz[MAX_FRAMES_IN_FLIGHT] pose_capacity;

	// ---- Compute skinning, which is opt-in per character ---------------------
	//
	// Built on the first frame that has a compute-routed character in it, and not
	// at all in a project that never asks for one — the shader is compiled at that
	// moment, like every other shader here.

	SkinPipeline skin_pipeline;
	// One posed copy of the mesh per instance, per frame in flight. The memory the
	// compute path costs and the vertex path does not, and the reason routing a
	// crowd through it would be the wrong trade: it is `vertices * copies * 24`
	// bytes times the frames in flight.
	vk::Memory[MAX_FRAMES_IN_FLIGHT] posed_buffers;
	sz[MAX_FRAMES_IN_FLIGHT] posed_capacity;
	// Where each bucket's posed vertices start, in vertices, filled by `prepare`
	// and read by `record`. Parallel to `Scene.buckets`; `NOT_PRESKINNED` for every
	// bucket the dispatch did not cover, which is most of them.
	List{uint} posed_offsets;

	// ---- The shadow pass, which is opt-in for the same reason -----------------
	//
	// No image, no shader and no pipeline until a script sets
	// `three.light.shadow.enabled`. `render/shadow.c3` is the whole of it; what
	// lives here is the two lines of the frame that reach it.
	ShadowMap shadows;
	<*
	 Which draw record each bucket got, or `NOT_DRAWN`.

	 Parallel to `Scene.buckets`, and it exists because the records have two
	 readers. A record is exactly what a bucket resolves to, so building it inside
	 `record`'s own loop would cost nothing extra — but the shadow pass reads the
	 same records and runs *before* that loop, so the resolution lives in `prepare`
	 and this is what both passes index it by. A second resolution in the shadow
	 pass would be a second place for "which mesh, which material, is this bucket
	 skinned" to be answered.
	*>
	List{uint} draw_indices;

	<*
	 What `prepare` resolved and `record` needs, for the one frame between them.

	 A compute dispatch cannot be recorded inside a render pass, so the work that
	 would otherwise sit at the top of `record` — updating the scene, writing the
	 frame's buffers, skinning — happens before `begin_render`, and `record` is the
	 commands that draw. These are the handful of numbers that cross between them.
	*>
	Matrix4f frame_view_projection;
	ulong frame_address;
	ulong instance_address;
	ulong draw_address;
	// Where this frame's spilled uniform tables are, or 0 when no material spilled
	// — `write_tables`.
	ulong table_address;
	ulong live_address;
	// False when `prepare` found nothing to draw, which is what `record` returns on
	// rather than repeating the emptiness checks.
	bool prepared;

	<*
	 Which debug view the shading pass draws, or `DEBUG_VIEW_OFF`.

	 Not scene state, and so not reset by `new three.Scene()`. It belongs with the
	 camera and `three.controls.enabled` on the other side of that line: a script
	 rebuilding the world is not a reason to put a diagnostic somebody is reading
	 back to normal, and a view that switched itself off every time a scene was
	 rebuilt would be unusable from the one place it is most needed.
	*>
	uint debug_view;

	bool ready;
}

// A bucket the compute pass did not skin. Not zero, because zero is a legitimate
// offset for the first bucket that it did.
const uint NOT_PRESKINNED = uint::max;

// A bucket that resolved to nothing and is drawn by neither pass — see
// `MeshPass.build_draw_records`. Not zero for `NOT_PRESKINNED`'s reason.
const uint NOT_DRAWN = uint::max;

<*
 Compiles the mesh shader and builds the pipeline from it.

 The `.slang` source is read and compiled at startup, which is why editing
 `shaders/mesh.slang` and re-running shows the change with no build step in
 between.

 The source is `shader_source`'s — the search path when there is a checkout, the
 copy embedded in the binary when there is not. A `--shader <path>` parameter
 could only ever name *this* template: `material.slang`, `post.slang`,
 `shadow.slang` and `skin.slang` are looked up the same way from four other
 places, so a run that pointed one of the five somewhere else got as far as the
 first `ShaderMaterial` and then failed with `SHADER_NOT_FOUND`.
*>
fn MeshPass? MeshPass.init(&self, Gpu* gpu, Target* target)
{
	self.pipelines.init();
	// One entry per bucket, rewritten every frame. Sized like the instance array
	// and for the same reason.
	self.posed_offsets.init(mem, INITIAL_INSTANCES);
	// Beside it, sized the same and rewritten every frame for the same reason.
	self.draw_indices.init(mem, INITIAL_INSTANCES);
	// Off, at the default size, with the default bias and intensity. A function
	// rather than four assignments here, because `new three.Scene()` restores the
	// same four and two spellings of a default drift.
	self.shadows.defaults();
	// Running, at ordinary speed. The zero value of a `GameClock` is a stopped one
	// — see `GameClock.defaults`.
	self.clock.defaults();

	@pool()
	{
		// The name rather than a path: the template may have come from the search
		// path or from the copy in the binary, and what `acquire` wants it for is a
		// cache key and a diagnostic label. A key that changed with where the file
		// happened to be found would miss the cache for the same bytes.
		String source = shader_source("mesh.slang", tmem)!;
		String path = "mesh.slang";
		self.pipeline = self.pipelines.acquire(gpu, target, source, path, SOLID_STATE)!;

		// The line pipeline is the same shader over a different fixed-function state
		// — `LINE_STATE` has the argument — so this is a second `VkPipeline` and
		// *not* a second Slang call: `acquire` keys on the source as well as the
		// state, and the source is byte-identical.
		//
		// It draws nothing until a script asks for a helper. Built here anyway,
		// because building it on demand would put a 1 ms pipeline creation inside
		// whichever frame first added a box helper, and the whole point of a debug
		// tool is that reaching for it is free.
		self.line_pipeline = self.pipelines.acquire(gpu, target, source, path, LINE_STATE)!;

		// And the two blended variants, for the same reason and at the same price.
		// Neither is claimed by a built-in material, so unlike the two above they
		// take no second reference here: what `acquire` handed back is the pass's
		// own, and `create_texture_material` retains per material on top of it.
		self.alpha_pipeline = self.pipelines.acquire(gpu, target, source, path, ALPHA_STATE)!;
		self.additive_pipeline = self.pipelines.acquire(gpu, target, source, path, ADDITIVE_STATE)!;
	};

	// `DEFAULT_MATERIAL` is index 0 and is built here, before anything can ask for
	// a material, so `Node.material` never has to mean "none". Its uniform block is
	// empty: `mesh.slang` declares no fields past `flags`.
	//
	// `LINE_MATERIAL` is index 1 and is built beside it for the same reason: a
	// node's material is a `uint`, so the pass has to be able to hand out an index
	// that means "draw this as lines" before any script has asked for one.
	//
	// Both name `NO_TEXTURE` explicitly. Leaving it out would zero-fill the field
	// to texture 0, so every untextured node in the scene would draw with the first
	// image any asset happened to upload — see `Material.texture`.
	//
	// Both take a reference on the pipeline they draw with, on top of the one
	// `acquire` gave the field above. Every stored `MeshPipeline*` in this file is
	// a counted borrow without exception — the alternative, "the pass's own two are
	// special", is a rule that has to be remembered at every future release.
	self.materials.init(mem, 4);
	// Before the two claims below and not after them, because `claim_slot` counts
	// through `note_material_claimed` and a threshold still at its zero fill is a
	// threshold every claim is already past: the built-ins warned about themselves.
	self.material_warn_at = MATERIAL_WARN_AT;
	self.pipelines.retain(self.pipeline);
	self.claim_slot({
		.pipeline = self.pipeline, .cull = CULL_MODE_BACK_BIT, .fragment = "", .texture = NO_TEXTURE
	});
	// No culling for lines: a segment has no facing, and `CULL_MODE_NONE` is what
	// keeps a wireframe from losing half its edges to a rule about triangles.
	self.pipelines.retain(self.line_pipeline);
	self.claim_slot({
		.pipeline = self.line_pipeline, .cull = CULL_MODE_NONE, .fragment = "", .texture = NO_TEXTURE
	});
	// After the two above rather than before them, which is what makes
	// `live_materials` mean "materials a script made and could dispose". The two
	// built-in slots are refused by `editable` and are never collected, so
	// counting them would put a permanent 2 into the number a script watches and
	// into every sentence `note_material_claimed` prints.
	self.live_materials = 0;

	self.assets.init(gpu);
	self.init_scenes();
	self.camera = default_camera();
	self.light = DEFAULT_LIGHT;
	// The first `frame_camera` can run before any frame has been recorded — the CLI
	// loads a file and fits the camera to it during startup — so the aspect starts
	// from the target rather than from zero. A zero-height target would make this a
	// NaN that `frame_bounds` reads as "no aspect given"; it is guarded there
	// rather than here, because the same is true of every later resize and one
	// guard at the point of use is the one that cannot be missed.
	self.aspect = (float)target.extent.width / (float)target.extent.height;

	// Set here rather than by the loaders, which is where it used to be and was a
	// bug: `ready` guards `record` against running without a *pipeline*, and the
	// pipeline exists as of this function. Gating it on a load instead meant the
	// three CLI entry points switched rendering on and the JS path — which calls
	// `Assets.load` directly — did not, so `three.render()` from a script drew
	// nothing at all. Nothing caught it because no JS test asserted on pixels, and
	// a blank PNG comes back fine.
	//
	// An empty scene is already handled a few lines into `record`, where zero
	// buckets returns, so this is not a weaker guard than what it replaces.
	self.ready = true;
	return *self;
}

<*
 A new, empty scene, counted and attached to this pass's asset table.

 Does *not* activate it — `js_scene_activate` is the only thing that moves
 `self.scene`, so that the switch and everything it resets live in one place.

 @return `The scene. Owned by this pass, and freed by dispose_scene or by free.`
*>
fn Scene* MeshPass.new_scene(&self)
{
	Scene* fresh = mem::new(Scene);
	fresh.init();
	// The scene counts references against this table from here on — see
	// `Scene.attach_assets`. Wired at construction rather than at first load,
	// because a node created before the wiring would never be counted and the asset
	// it named could then be swept out from under it.
	fresh.attach_assets(&self.assets);
	self.scenes.push(fresh);
	self.note_scene_created();
	return fresh;
}

<*
 The scene list, with one empty scene in it.

 Split out of `init` because the test harnesses build a `MeshPass` by hand — a
 pipeline wants a GPU and the scene layer does not — and a second spelling of
 "how a pass gets its first scene" is how one of the two ends up not counting.

 `Assets.init` first, so that the scene attaches to a table that exists.
*>
fn Scene* MeshPass.init_scenes(&self)
{
	self.scenes.init(mem, 4);
	self.scene_warn_at = SCENE_WARN_AT;
	self.scene = self.new_scene();
	self.bootstrap = self.scene;
	return self.scene;
}

// Every scene, not just the active one: a scene a script never disposed still
// owns a node pool, a physics world and a nav bake.
fn void MeshPass.free_scenes(&self)
{
	foreach (each : self.scenes)
	{
		each.free();
		mem::free(each);
	}
	self.scenes.free();
	self.scene = null;
	self.bootstrap = null;
}

<*
 The scene a `new three.Scene()` gets.

 A pass has a scene before any script runs — the command line can load a model
 into one — so a run that never claimed it would report two scenes for a script
 holding one, and would warn about a leak that is the pass's own bootstrap.
 The first `new three.Scene()` takes it over instead.

 Only while it is empty. A model loaded from the command line is a scene somebody
 built, and `new three.Scene()` does not empty a scene any more — so that case
 gets a fresh one and the loaded model stays exactly where it is.

 Once, whatever happens. A second `new three.Scene()` is always a second scene,
 because two empty scenes a script asked for separately have to be separate: the
 alternative is `a.add(...)` landing in `b`.
*>
fn Scene* MeshPass.claim_scene(&self)
{
	Scene* first = self.bootstrap;
	self.bootstrap = null;
	if (first == null) return self.new_scene();

	Node* root = first.node(first.root);
	if (root == null || root.children.len() > 0) return self.new_scene();
	return first;
}

fn Scene* MeshPass.scene_by_id(&self, uint id)
{
	foreach (each : self.scenes)
	{
		if (each.id == id) return each;
	}
	return null;
}

<*
 Frees a scene and everything it owns.

 Refuses the active one. A frame with no scene to draw is a black window, which
 reads as the renderer being broken rather than as the script having freed the
 world it was looking at — so the answer is no, and the caller is told to
 activate another first.

 The asset references its nodes held are given back by `Scene.free` through
 `kill`, so a sweep afterwards is what actually reclaims memory. Two scenes over
 one kit means disposing either frees nothing, which is the right answer.

 @return `false if the id names nothing, or names the active scene.`
*>
fn bool MeshPass.dispose_scene(&self, uint id)
{
	if (self.scene != null && self.scene.id == id) return false;
	foreach (i, each : self.scenes)
	{
		if (each.id != id) continue;
		each.free();
		mem::free(each);
		self.scenes.remove_at(i);
		return true;
	}
	return false;
}

const uint SCENE_WARN_AT = 4;

<*
 Says something the first time the number of live scenes looks like a leak.

 `new three.Scene()` no longer frees the scene it replaced — that is what makes
 building the next level while the current one is on screen possible, and it is
 also what makes a game that transitions eight times hold eight worlds. Nothing
 else would say so: the old scene is not drawn, not stepped and not queried, so
 it costs frame time nothing and memory everything.

 Doubling, to stderr, and never reset downwards — `note_material_claimed` has
 the argument for all three.
*>
fn void MeshPass.note_scene_created(&self)
{
	if (self.scenes.len() < self.scene_warn_at) return;

	io::eprintfn(
		"three: %d live scenes. new three.Scene() no longer empties the one before "
		"it — each keeps its nodes, its bodies and its asset references until "
		"scene.dispose(). stats().scenes is the number to watch.",
		self.scenes.len()
	);
	self.scene_warn_at *= 2;
}

<*
 Puts a material in the table and answers the index that names it.

 The one place a material becomes live. `alive` is never written at a
 construction site, so C3's zero fill cannot produce a material that is dead the
 moment it is built — the mirror of the hazard `Material.texture` describes.

 A collected slot is reused before the list grows. That keeps an agent building a
 material per run from growing this table for the life of the process, and it is
 safe for the same reason the collection was: a slot is only free once no node
 names it and the script's handle has been given back.
*>
fn uint MeshPass.claim_slot(&self, Material material)
{
	material.alive = true;
	self.note_material_claimed();

	foreach (i, &existing : self.materials)
	{
		if (existing.alive) continue;
		*existing = material;
		// After the copy, and on the stored one. `bind_table` allocates, and a table
		// allocated on the by-value parameter would be freed with it. This is the
		// only choke point where a material becomes live, which is why it is also
		// the only place that has to remember.
		existing.bind_table();
		return (uint)i;
	}

	uint index = (uint)self.materials.len();
	self.materials.push(material);
	self.materials[index].bind_table();
	return index;
}

<*
 How many live materials it takes before the first word about disposing them.

 A material an agent compiled holds a `VkPipeline` until `material.dispose()`
 gives it back, and `PipelineCache`'s eviction cannot help: an entry with a live
 material on it has a reference and is never unused. So a script that builds a
 material and drops the handle leaks one pipeline per distinct shader source, for
 the life of the process, exactly as the entry in `plan.md` §2 said it would.

 The answer is a warning and not a `FinalizationRegistry`, and that was decided
 before it was written: a collector-driven free makes device memory depend on
 when QuickJS felt like collecting, which is the property `three.unloadUnused()`
 exists to avoid for assets and would be no better here.

 Sixty-four because it is comfortably above every legitimate scene anybody has
 written here — `examples/village.js` is under ten, and a kit imported with
 `{ materials: true }` is one per distinct glTF material — and comfortably below
 the count at which a per-frame build has done real damage.
*>
const uint MATERIAL_WARN_AT = 64;

<*
 Counts a material into the table, and says something the first time the count
 looks like a leak.

 Doubling rather than warning per creation, because the script this is aimed at
 builds materials in a loop and a line per creation would bury the one that
 mattered. Nothing resets it downwards: a count that fell back under the
 threshold and warned again at the same number would say the same sentence
 forever to a script that is cycling materials correctly.

 Written to stderr rather than raised. It is a diagnostic about a shape, not a
 fault — every one of those materials draws correctly — and a throw would break
 the one script that legitimately holds a hundred.
*>
fn void MeshPass.note_material_claimed(&self)
{
	self.live_materials++;
	if (self.live_materials < self.material_warn_at) return;

	io::eprintfn(
		"three: %d live materials, and each one holds its pipeline until "
		"material.dispose() gives it back — %d distinct pipelines so far. "
		"stats().materials is the number to watch.",
		self.live_materials,
		self.pipelines.entries.len()
	);
	self.material_warn_at *= 2;
}

<*
 Resolves a material index.

 @return `The material, or null if the index names nothing — which the draw loop treats as "skip this bucket" rather than as a fault.`
*>
fn Material* MeshPass.material(&self, uint index)
{
	if (index >= self.materials.len()) return null;
	Material* material = &self.materials[index];
	// A collected slot names nothing. It answers null rather than handing back the
	// zeroed struct, which would resolve to a null pipeline and crash the draw loop
	// instead of skipping the bucket the way an unknown index does.
	if (!material.alive) return null;
	return material;
}

<*
 The material an agent is allowed to change, or a fault saying why not.

 The built-in materials are refused. `DEFAULT_MATERIAL` is shared by every node
 that was never given one of its own and `LINE_MATERIAL` by every debug line, so
 editing either would reach across every node at once through a handle that reads
 like it names one thing. Every setter below goes through here, which keeps that
 rule in one place rather than in each of them.

 @return? MATERIAL_UNKNOWN : `No such material, or one of the two built-in ones, which are shared.`
*>
fn Material*? MeshPass.editable(&self, uint index)
{
	if (index == DEFAULT_MATERIAL || index == LINE_MATERIAL) return MATERIAL_UNKNOWN~;
	Material* material = self.material(index);
	if (material == null) return MATERIAL_UNKNOWN~;
	return material;
}

<*
 Loads a `.glb` and puts one node on screen for each mesh in it.

 The flat placement is deliberate: this is the CLI's "show me this file", not a
 scene author's `add`. Anything with a hierarchy comes from JS, through the same
 `Scene.add_mesh` this uses.
*>
fn void? MeshPass.load(&self, Gpu* gpu, String path)
{
	AssetId asset = self.assets.load(gpu, path)!;
	self.place(asset, NO_NODE);
	self.frame_camera();
}

<*
 Loads the built-in triangle — what `three` shows when given no file.

 It exists to prove the geometry path on its own: a hardcoded triangle rendering
 through a buffer device address, separate from the glTF loader, so a blank
 window after loading a `.glb` is unambiguous about which half broke.
*>
fn void? MeshPass.load_triangle(&self, Gpu* gpu)
{
	AssetId asset = self.assets.load_triangle(gpu)!;
	self.place(asset, NO_NODE);
	self.frame_camera();
}

<*
 An asset's node hierarchy, under `parent`.

 `Scene.instantiate` is where the hierarchy is built and where the reasons are
 written down; this stays as the verb `load` and `load_triangle` reach for.

 @return `The group the asset was instantiated into, or the parent it was given if the handle names nothing.`
*>
fn NodeId MeshPass.place(&self, AssetId asset, NodeId parent)
{
	NodeId group = self.scene.instantiate(asset, parent);
	return group.is_set() ? group : parent;
}

<*
 Aims the camera at everything in the scene.

 Refitted here rather than left where it was because the caller has no idea how
 big the scene's contents are — see `Camera.frame_bounds`.
*>
fn void MeshPass.frame_camera(&self)
{
	collision::Aabb3 bounds = self.scene.bounds(&self.assets);
	self.camera.frame_bounds(bounds.min, bounds.max, self.aspect);
}

fn collision::Aabb3 MeshPass.bounds(&self) => self.scene.bounds(&self.assets);

<*
 Re-derives the camera's near and far planes against what the scene actually
 holds.

 `Camera.derive_planes` on its own only knows the orbit distance, and the far
 plane it picks from that is a guess that fails silently. This is the caller that
 has a scene to measure, so it measures: the eye's distance to the far side of
 the bounding sphere is exactly how far the camera can need to see, and the
 multiple-of-distance floor stays underneath it.

 The bounding *sphere* rather than the box's furthest corner, for
 `frame_bounds`'s reason: it is orientation independent, so the answer does not
 change as the turntable turns and the far plane does not breathe during a drag.

 Costs nothing in a frame where nothing moved. `Scene.bounds` is exact rather
 than conservative — every vertex of every drawable mesh through a matrix — and a
 follow camera calls this every tick, so a followed scene would otherwise pay
 that per frame on top of the walk `MeshPass.prepare` already does for the shadow
 fit. It is cached behind `Scene.bounds_current`, and the invalidation that is
 the whole of the risk is `Scene.invalidate`.

 An empty scene answers with a unit box, whose reach is under the floor, so
 nothing special-cases it.
*>
fn void MeshPass.derive_camera_planes(&self)
{
	collision::Aabb3 bounds = self.scene.bounds(&self.assets);
	self.camera.derive_planes((self.camera.eye() - bounds.center()).length() + bounds.extent().length());
}

<*
 Records the draws.

 @param slot : `Which frame in flight this is. Selects the instance array and the draw records to write, and must be one whose fence has already been waited on.`
*>
fn void? MeshPass.prepare(&self, Gpu* gpu, vk::CommandBuffer cmd, Target* target, uint slot)
{
	self.prepared = false;
	if (!self.ready) return;

	// Before the draw list is built, so a material whose last node died in the same
	// breath as the dispose does not have its pipeline held for one more frame than
	// it needs to be. Costs nothing unless something is pending.
	self.collect_materials(gpu);

	float aspect = (float)target.extent.width / (float)target.extent.height;
	// Remembered for `frame_camera`, which runs between frames and so has no target
	// of its own to measure. A resize therefore reaches the next fit.
	self.aspect = aspect;
	Matrix4f view_projection = self.camera.view_projection(aspect);

	// The whole of what `Scene` is told about materials, and deliberately not a
	// pointer to them. The scene graph has no view of `MeshPass.materials`, and
	// giving it one would put the render pass inside the scene graph to save a
	// loop. Draw ordering needs exactly one bit per material index — does this one
	// blend — so one bit per index is what crosses: a flat `bool[]` off the temp
	// arena, built here, read only for the length of the call.
	//
	// Indexed by material index and exactly as long as the table, so a node naming
	// a material past the end reads as opaque — the right answer for a bucket the
	// draw loop is going to skip anyway. `alive` is asked for the same reason
	// `MeshPass.material` asks it.
	//
	// The bones settle before the draw list is built, and the order is
	// load-bearing: `write_live_poses` reads every bone's world matrix and writes
	// each live character's slice offset back into its node, and `build_draw_list`
	// then copies that offset into the instance array. Run the other way round and
	// a live character is drawn with last frame's offset — invisible while nothing
	// is moving and a frame of lag the moment something is.
	//
	// `update_world_matrices` runs again inside `scene.update` below and costs
	// nothing the second time: `Scene.matrices_current` turns the traversal into a
	// compare.

	self.scene.update_world_matrices();
	ulong live_address = self.write_live_poses(gpu, slot)!;

	// Before the draw list, because the draw list depends on the answer. A caster
	// the camera cannot see still throws a shadow into the frame, so a frame with a
	// shadow pass builds its list against the light's box as well as the camera's.
	// Deciding this after `scene.update` would mean a shadow map missing exactly
	// the casters that matter, and nothing anywhere saying so.
	//
	// The fit needs the image, because the texel size and the normal offset are
	// derived from the size it was actually created at; and it needs the world
	// bounds, which `update_world_matrices` above has just made current.
	self.shadows.live = false;
	if (self.shadows.enabled)
	{
		// A shadow map that will not build turns shadows off rather than killing the
		// frame. Both of these can fail — an image allocation, a Slang compile — and
		// propagating the fault would stop the renderer drawing anything at all,
		// every frame, because `prepare` would retry and fail again.
		//
		// `enabled` is cleared rather than only `live`, so it is one message and not
		// one per frame, and so a script reading `three.light.shadow.enabled` back
		// is told the truth.
		if (catch self.shadows.ensure(gpu))
		{
			io::eprintn("three: the shadow map could not be created — shadows are off");
			self.shadows.enabled = false;
		}
		else if (catch self.shadows.build_pipeline(gpu))
		{
			io::eprintn("three: the shadow shader could not be built — shadows are off");
			self.shadows.enabled = false;
		}
		else
		{
			// The two boxes the fit splits. `bounds` is everything drawable and
			// decides where the light stands and how far it reaches; the focus is
			// what the camera can actually see, clipped to the same box, and is what
			// the texels are spent on. Intersected here rather than inside `fit`
			// because this is the only place that has a camera.
			collision::Aabb3 bounds = self.scene.bounds(&self.assets);
			collision::Aabb3 seen = self.camera.view_bounds(aspect, self.shadows.reach(self.camera.distance));
			collision::Aabb3 focus = {
				.min = math::max(seen.min, bounds.min),
				.max = math::min(seen.max, bounds.max),
			};
			// Stable only when there is something to keep. A fit that recentres
			// every frame throws away a cached shadow map every frame; a fit that
			// holds still spends texel density to avoid that. `ShadowMap.fit`'s
			// header has the numbers, and this is the one line that decides which
			// scene is which.
			self.shadows.fit(self.light, bounds, focus, stable: self.scene.static_nodes > 0);
			self.shadows.live = true;
		}
	}

	@pool()
	{
		bool[] transparent = alloc::new_array(tmem, bool, self.materials.len());
		// Beside it and built in the same pass, because it answers a question of the
		// same shape — something the *material* knows that the *scene* needs while
		// it is culling. See `Material.bounds`.
		float[] margins = alloc::new_array(tmem, float, self.materials.len());
		foreach (i, &material : self.materials)
		{
			transparent[i] = material.alive && material.blend != BlendMode.NONE;
			margins[i] = material.alive ? material.bounds : 0;
		}
		// The fit above wrote `light_view_projection`, so the box the pass will
		// rasterise into and the box the cull is against are the same box by
		// construction rather than by two agreeing derivations.
		self.scene.update(
			&self.assets, view_projection, transparent, margins,
			self.shadows.live ? &self.shadows.light_view_projection : null
		);
	};
	if (self.scene.buckets.len() == 0)
	{
		// Nothing to cast and nothing to receive, so there is no pass — and saying
		// so here rather than letting `record_shadow` discover it is what keeps the
		// frame block, the draw list and the pass agreeing about one field.
		self.shadows.live = false;
		self.shadows.draws = 0;
		return;
	}

	FrameBlock frame = {
		.view_projection = view_projection,
		.light = self.light,
		.live_poses = live_address,
		.light_view_projection = self.shadows.light_view_projection,
		.shadow = self.shadows.params(),
		.debug = { (float)self.debug_view, 0, 0, 0 },
	};
	self.frame_view_projection = view_projection;
	self.live_address = live_address;
	self.frame_address = self.write_frame_block(gpu, slot, &frame)!;
	self.instance_address = self.write_instances(gpu, slot)!;

	// Sized against every bucket, including the ones that resolve to nothing. Their
	// records are stale bytes nothing points at — `build_draw_records` only
	// advances the counter for a bucket that draws — and the alternative is a count
	// that has to predict which buckets those are.
	self.reserve_draws(gpu, slot, self.scene.buckets.len())!;
	self.draw_address = self.draw_buffers[slot].address;
	self.write_tables(gpu, slot)!;

	// Outside the render pass, which is the whole reason this phase exists.
	// `vkCmdDispatch` is illegal between `vkCmdBeginRendering` and
	// `vkCmdEndRendering`, so a compute-skinned bucket has to be posed here, one
	// barrier before the first draw reads the result.
	self.skin(gpu, cmd, slot)!;

	// After the dispatch, not before it. A pre-skinned bucket's record points into
	// the output buffer `skin` just sized and may have just reallocated, and the
	// offsets it writes are what `FLAG_PRESKINNED` means — so a record built first
	// would name last frame's buffer.
	self.build_draw_records(slot);

	// Last, because it is the only decision here that needs the finished draw
	// list: which shape the shadow pass takes follows from how many casters are
	// static and how many are not, and neither number exists until the buckets do.
	self.plan_shadow(gpu);

	self.prepared = true;
}

<*
 Decides which of the three shapes this frame's shadow pass takes.

 Counted off the buckets rather than off a flag on the scene, because the
 question is not "did a script mark anything static" but "is there anything
 static *that casts*": a static node under a blended material contributes nothing
 to the map, and a scene of nothing but glass walls would otherwise allocate a
 second 16 MB image to hold a picture of nothing.

 `SHADOW_PLAN_FULL` is the answer to everything that goes wrong, and it is the
 renderer exactly as it was before caching existed. A scene with nothing static,
 an image that would not allocate — each lands here and the frame draws the map
 the way it always did. That is the same choice `prepare` makes about the map as
 a whole: a feature that could not be built is a frame without it, never a frame
 that does not draw.
*>
fn void MeshPass.plan_shadow(&self, Gpu* gpu)
{
	self.shadows.plan = SHADOW_PLAN_FULL;
	self.shadows.sample_static = false;
	if (!self.shadows.live) return;

	uint statics = 0;
	uint movers = 0;
	foreach (bucket : self.scene.buckets)
	{
		Material* material = self.material(bucket.material);
		if (material == null || !self.casts_shadow(material)) continue;
		if (self.assets.mesh(bucket.asset, bucket.mesh) == null) continue;
		statics += bucket.static_count;
		movers += bucket.count - bucket.static_count;
	}

	if (statics == 0 || self.shadows.static_refused) return;

	// Allocated the first frame a static caster casts, and not before. A script may
	// write `mesh.static = true` at any moment; the image can only be created
	// between frames, and this is between frames.
	if (catch self.shadows.ensure_static(gpu))
	{
		// One message and then the ordinary path forever, which is `prepare`'s rule
		// for the map itself: the frame still draws, the shadows are still right,
		// and the only thing lost is the saving. `static_refused` keeps it to one
		// sentence rather than sixty a second.
		io::eprintn("three: the cached shadow map could not be created — every caster is drawn each frame");
		self.shadows.static_refused = true;
		return;
	}
	if (self.shadows.static_image == null) return;

	self.shadows.plan = movers == 0 ? SHADOW_PLAN_STATIC : SHADOW_PLAN_COMBINED;
	// A frame in which nothing casting moves reads the cached image itself. See
	// `ShadowMap.sample_static` for why that is not merely an optimisation of the
	// copy — it is the frame that records nothing at all.
	self.shadows.sample_static = self.shadows.plan == SHADOW_PLAN_STATIC;
}

<*
 One `DrawRecord` per bucket that draws, and the index of each in
 `self.draw_indices`.

 Its own pass over the buckets rather than part of `MeshPass.record`'s loop,
 because the shadow pass reads the same records — the same geometry, the same
 instances, the same skinning — and records *before* the render pass begins. With
 the records written inside the draw loop it would have to resolve every bucket
 itself, which is the second copy of the resolution the single-loop arrangement
 was avoiding, arrived at from the other side.

 The buffer is host-visible and coherent and the frame is not submitted until
 recording ends, so writing it here is the same thing as writing it during the
 draw.

 @param slot : `The frame in flight whose draw and posed buffers these records point into.`
*>
fn void MeshPass.build_draw_records(&self, uint slot)
{
	self.draw_indices.clear();

	DrawRecord* records = (DrawRecord*)self.draw_buffers[slot].data();
	uint recorded = 0;

	foreach (i, bucket : self.scene.buckets)
	{
		GpuMesh* mesh = self.assets.mesh(bucket.asset, bucket.mesh);
		if (mesh == null)
		{
			self.draw_indices.push(NOT_DRAWN);
			continue;
		}

		// A bucket whose material does not resolve is skipped rather than drawn with
		// the default. Falling back would put the wrong shader on screen and look
		// like a shader bug; drawing nothing looks like what it is.
		Material* material = self.material(bucket.material);
		if (material == null)
		{
			self.draw_indices.push(NOT_DRAWN);
			continue;
		}

		// The mesh's own factor, faded by the material's opacity. Multiplied rather
		// than replaced so a glTF's own alpha and a script's `opacity` compose — the
		// file said what the surface is, the script says how much of it to show.
		//
		// Costs nothing on an opaque material: `Material.opacity` is 1 unless
		// somebody set it, and the opaque pipeline discards the alpha regardless.
		float[4] base_color = mesh.base_color;
		base_color[3] *= material.opacity();

		// Both halves or neither. A mesh carries influences and an asset carries the
		// table they index; either one without the other is a palette read through a
		// null pointer, which is a device-lost rather than a bad picture.
		Asset* owner = self.assets.slot(bucket.asset);
		bool skinned = mesh.has_skin && owner != null && owner.poses.buffer != null;

		// The two skinning paths are exclusive, and the record says which one this
		// bucket took. A pre-skinned bucket's vertices were posed before the render
		// pass began, so the vertex shader must read them and blend nothing;
		// `skin_stride` is how it finds this copy's own posed vertices inside the
		// shared output buffer.
		uint posed_offset = i < self.posed_offsets.len() ? self.posed_offsets[i] : NOT_PRESKINNED;
		bool preskinned = skinned && posed_offset != NOT_PRESKINNED;
		if (preskinned) skinned = false;

		records[recorded] = {
			.positions = mesh.positions.address,
			.normals = mesh.has_normals ? mesh.normals.address : 0,
			.uvs = mesh.has_uvs ? mesh.uvs.address : 0,
			.colors = mesh.has_colors ? mesh.colors.address : 0,
			.joints = skinned ? mesh.joints.address : 0,
			.weights = skinned ? mesh.weights.address : 0,
			.palette = skinned ? owner.poses.address : 0,
			.posed = preskinned
				? self.posed_buffers[slot].address + (ulong)posed_offset * SkinnedVertex::size
				: 0,
			.base_color = base_color,
			.flags = (mesh.has_normals ? FLAG_HAS_NORMALS : 0)
				| (mesh.has_uvs ? FLAG_HAS_UVS : 0)
				| (mesh.has_colors ? FLAG_HAS_COLORS : 0)
				| (skinned ? FLAG_HAS_SKIN : 0)
				| (preskinned ? FLAG_PRESKINNED : 0),
			.skin_stride = preskinned ? mesh.vertex_count : 0,
			.uv_transform = material.uv_transform_or_identity(),
		};

		self.draw_indices.push(recorded);
		recorded++;
	}
}

<*
 The draw commands, recorded inside the render pass.

 Everything this needs was resolved by `prepare` a moment ago and is on `self`.

 @param cmd : `A command buffer inside a render pass, on a frame prepare has run for.`
*>
fn void MeshPass.record(&self, vk::CommandBuffer cmd)
{
	if (!self.prepared) return;

	ulong frame_address = self.frame_address;
	ulong instance_address = self.instance_address;
	ulong draw_address = self.draw_address;

	// Bound per bucket, because a bucket is `(asset, mesh, material)` and the
	// material chooses the pipeline. `build_draw_list` sorts material-major
	// precisely so this stays one bind per material rather than one per bucket —
	// `bound` is what turns that ordering into skipped calls.
	vk::Pipeline bound = (vk::Pipeline)null;

	foreach (i, bucket : self.scene.buckets)
	{
		// The one skip, and `build_draw_records` already made the decision. A bucket
		// with no mesh or no material got `NOT_DRAWN` there rather than being
		// skipped again here, so the two passes over the buckets cannot disagree
		// about which ones draw.
		uint at = i < self.draw_indices.len() ? self.draw_indices[i] : NOT_DRAWN;
		if (at == NOT_DRAWN) continue;
		// `visible`, not `count` — the tail of a bucket is the copies only the light
		// can see, and drawing them here would put geometry on screen the camera
		// frustum rejected. `Bucket.visible` has why they are a prefix.
		//
		// Here rather than at the draw call, so a bucket the camera cannot see at
		// all costs nothing instead of a pipeline bind, a cull mode, a descriptor
		// collect and a push. With a shadow pass on, a caster behind the camera is
		// the ordinary case.
		if (bucket.visible == 0) continue;

		GpuMesh* mesh = self.assets.mesh(bucket.asset, bucket.mesh);
		Material* material = self.material(bucket.material);
		if (mesh == null || material == null) continue;
		MeshPipeline* pipeline = material.pipeline;

		if (pipeline.handle != bound)
		{
			vk::cmdBindPipeline(cmd, PIPELINE_BIND_POINT_GRAPHICS, pipeline.handle);
			bound = pipeline.handle;
		}

		// Dynamic, so `material.side` costs a command rather than a pipeline — see
		// `PipelineState`. Set per bucket rather than tracked like `bound`, because
		// the draw list is material-major already: consecutive buckets usually share
		// a material and the driver folds a repeated set, whereas a `last_cull`
		// variable would be a second thing to keep in step with the pipeline bind
		// for no measured gain.
		vk::cmdSetCullMode(cmd, material.cull);

		// Pushed, not bound. There is no descriptor set anywhere in this project:
		// the image and sampler are specified inline against this pipeline's own
		// layout, so a material's shader gets its texture through its own layout
		// rather than through one baked at load time against a different pipeline.
		//
		// The material's own texture wins over the mesh's. `material.map` is the
		// explicit statement and the mesh's image is what a file happened to bring,
		// so a script that sets one and gets the other would be overruled by an
		// asset it did not write. This costs nothing to decide here: the descriptor
		// is already written per bucket, and a bucket is `(asset, mesh, material)` —
		// so two nodes over one mesh with different maps are already two buckets.
		Texture* sampled = material.texture == NO_TEXTURE
			? self.assets.texture_for(mesh)
			: self.assets.texture_at(material.texture);

		// Binding 0 by hand and everything above it from the shader's own reflection
		// — `render/bind.c3` has the argument, and the short version is that only
		// this line knows binding 0 is "the material's map or the mesh's image". A
		// body that declared `noise_map` gets it at whatever index the assembler
		// generated, resolved by name, with white in any sampler the script left
		// empty.
		SampledBindings samplers;
		samplers.add(0, sampled.descriptor());
		// Binding 1, the other reserved one, and asked for by index rather than
		// assumed to be there: Slang may drop a sampler the linked program never
		// reads, and pushing a write for a binding the layout does not declare is a
		// validation error. Both templates read it today, so the answer is yes
		// today.
		//
		// The white 1x1 when there is no shadow pass, which is not a fallback but
		// the correct value: a depth of 1 is the far plane, nothing is in front of
		// anything, and `shadow_factor` comes out lit. So shadows on and shadows off
		// are the same pipeline and the same descriptor layout, differing by which
		// image is in one slot.
		if (pipeline_declares_binding(pipeline, SHADOW_BINDING))
		{
			samplers.add(
				SHADOW_BINDING,
				self.shadows.live
					? self.shadows.descriptor()
					: self.assets.texture_at(NO_TEXTURE).descriptor()
			);
		}
		samplers.collect(pipeline, &material.textures, &self.assets, MATERIAL_BINDING_FIRST);
		samplers.push(cmd, pipeline);

		MeshPush push = {
			.frame = frame_address,
			// Offset on the CPU rather than passed as a base index: the shader then
			// reads instance zero of its own slice and never has to know whether
			// SV_InstanceID includes firstInstance.
			.instances = instance_address + (ulong)bucket.first * Instance::size,
			// And this bucket's own record, for the same reason — `push.draw[0]` is
			// always the right one, whatever else is in the buffer.
			.draw = draw_address + (ulong)at * DrawRecord::size,
		};
		// The reflected size, not `MeshPush::size`. The two agree at 24 today and
		// have not always: the block used to end in a `uint` that C3 followed with
		// four bytes of tail padding, so Slang reported 76 where the struct occupied
		// 80, and pushing 80 into a 76-byte range is a validation error.
		//
		// Worth knowing how it fails, because it is not how it sounds: the picture
		// is pixel-identical either way on this driver, so no test here catches it
		// and only the validation layer does. It is still undefined behaviour, and a
		// driver that took the spec literally would drop the push and render
		// nothing.
		//
		// Both this and the range in `MeshPipeline.init` read the same reflected
		// field, so they cannot drift without an edit that hardcodes one of them.
		//
		// The mesh contract first, the material's uniforms on top of it. A
		// `Material.block` is laid out *as the push block itself* rather than as a
		// list of values, so this is two memcpys with no per-uniform loop and no
		// offset arithmetic here.
		char[PUSH_BUDGET] staging;
		uint push_size = pipeline.shader.push_size;
		mem::copy(&staging[0], (char*)&push, MeshPush::size);
		if (push_size > MATERIAL_PUSH_START)
		{
			mem::copy(
				&staging[MATERIAL_PUSH_START],
				&material.block[MATERIAL_PUSH_START],
				(sz)(push_size - MATERIAL_PUSH_START)
			);
		}

		// The spilled uniform table, if this material has one. Written over the
		// bytes the block copy above already put there — `material_table` is a
		// pointer field of the block like the other three, and `Material.block`'s
		// copy of it is stale by definition because the buffer moves every frame.
		if (material.table_pointer != NO_TABLE_POINTER && material.table.len > 0)
		{
			ulong table = self.table_address + (ulong)material.table_offset;
			mem::copy(&staging[material.table_pointer], (char*)&table, ulong::size);
		}

		vk::cmdPushConstants(cmd, pipeline.layout, pipeline.shader.stages, 0, push_size, &staging);

		// Index binding is independent of vertex bindings, which is why the pass can
		// have an index buffer and no vertex input state at all.
		vk::cmdBindIndexBuffer(cmd, mesh.indices.buffer, 0, INDEX_TYPE_UINT32);
		vk::cmdDrawIndexed(cmd, mesh.index_count, bucket.visible, 0, 0, 0);
	}
}

<*
 Whether this material's geometry is written into the shadow map.

 Two refusals, and both are about a pipeline rather than about the surface:

 - A blended material casts nothing. A shadow map holds one depth per texel, so a
   half-transparent surface can only be recorded as fully opaque or not at all —
   and glass that throws a solid black shadow is a worse answer than glass that
   throws none. The same reason `ALPHA_STATE` writes no depth in the main pass.
 - A line casts nothing. `LINE_STATE` has no depth test and no depth write
   precisely so a debug helper is never hidden by the scene it was drawn to
   explain; a helper that cast a shadow onto that scene would be the same mistake
   from the other side. Asked by pipeline rather than by material index, because
   `PipelineCache.acquire` hands the same pointer back for the same source and
   state — so this covers any material drawn as lines.

 What is deliberately *not* here is a per-node `castShadow`: a third per-copy
 channel splits buckets, which is the trade the whole renderer exists to refuse.
*>
fn bool MeshPass.casts_shadow(&self, Material* material)
{
	if (material.blend != BlendMode.NONE) return false;
	if (material.pipeline == self.line_pipeline) return false;
	return true;
}

<*
 The shadow map's draws — the frame's first pass, and the one that writes no
 colour.

 Between `prepare` and `begin_render`, the same window the compute skinning
 dispatch uses and for a related reason: this begins and ends a rendering of its
 own, and `vkCmdBeginRendering` cannot nest.

 It needs nothing `prepare` did not already resolve. The instance array, the draw
 records and the posed vertices are the *same buffers the main pass reads*, which
 is what makes a character's shadow the shadow of the pose it is actually in —
 and for a compute-skinned character it is where the blend having happened once,
 in a dispatch, finally pays: both passes read the result.

 Records nothing at all — no barrier, no clear, no transition — in a frame with
 no shadow pass.

 @param cmd : `A command buffer outside any rendering, on a frame prepare has run for.`
*>
fn void MeshPass.record_shadow(&self, vk::CommandBuffer cmd)
{
	self.shadows.draws = 0;
	self.shadows.static_draws = 0;
	if (!self.prepared || !self.shadows.live) return;

	// The renderer as it was before caching: one clear, every caster, one image.
	if (self.shadows.plan == SHADOW_PLAN_FULL)
	{
		self.shadows.begin(cmd);
		self.shadows.draws = self.record_casters(cmd, CASTERS_ALL);
		self.shadows.end(cmd);
		return;
	}

	// The rebuild, on the frames there is one. `static_current` is the whole of the
	// invalidation; what matters here is that the answer is usually yes, and that a
	// yes means the next two lines are the only ones this function runs.
	if (!self.shadows.static_current(self.scene.static_revision))
	{
		self.shadows.begin_static(cmd);
		self.shadows.static_draws = self.record_casters(cmd, CASTERS_STATIC);
		self.shadows.end_static(cmd);
		self.shadows.mark_static_built(self.scene.static_revision);
	}

	// Nothing else at all. No clear, no copy, no draws, no barriers: the cached
	// image is left where `end_static` put it and the colour pass samples it
	// directly. A village in which the sun does not move and the buildings do not
	// move costs its shadow map once and then nothing.
	if (self.shadows.plan == SHADOW_PLAN_STATIC) return;

	self.shadows.copy_static(cmd);
	self.shadows.begin_over_copy(cmd);
	self.shadows.draws = self.record_casters(cmd, CASTERS_DYNAMIC);
	self.shadows.end(cmd);
}

<*
 Draws one half of the casters, or both, into whatever depth attachment is open.

 @param which : `CASTERS_ALL, CASTERS_STATIC or CASTERS_DYNAMIC — see Bucket.static_first for the layout these select out of each bucket.`
 @return `How many draw calls were recorded, which is what stats() reports.`
*>
fn uint MeshPass.record_casters(&self, vk::CommandBuffer cmd, uint which)
{
	// One bind for the whole pass. There is no material in a depth pass and so
	// nothing to change pipelines for — the counterpart to `record`'s `bound`
	// tracking, which exists because a bucket there chooses its own shader.
	vk::cmdBindPipeline(cmd, PIPELINE_BIND_POINT_GRAPHICS, self.shadows.pipeline.handle);

	// No `cmdSetCullMode`: `init_shadow` bakes CULL_MODE_NONE in and does not
	// declare the dynamic state, so `material.side` is deliberately not honoured
	// here. A single-sided wall still casts the shadow of both its faces, which is
	// the same shadow.
	uint recorded = 0;

	foreach (i, bucket : self.scene.buckets)
	{
		uint at = i < self.draw_indices.len() ? self.draw_indices[i] : NOT_DRAWN;
		if (at == NOT_DRAWN) continue;

		GpuMesh* mesh = self.assets.mesh(bucket.asset, bucket.mesh);
		Material* material = self.material(bucket.material);
		if (mesh == null || material == null) continue;
		if (!self.casts_shadow(material)) continue;

		// The four cells of `Bucket.static_first`, read back out. `tail` is the
		// hidden dynamic copies, which are the one group that is not adjacent to its
		// own kind — the cost the layout pays to keep `visible` a prefix.
		uint tail_at = bucket.static_first + bucket.static_count;
		switch (which)
		{
			case CASTERS_ALL:
				// `count`, not `visible` — the counterpart of the line in `record`.
				// This pass wants every copy the light's box kept, which is the
				// visible prefix plus the tail of casters the camera cannot see.
				recorded += self.draw_casters(cmd, mesh, bucket, at, 0, bucket.count);
			case CASTERS_STATIC:
				recorded += self.draw_casters(cmd, mesh, bucket, at, bucket.static_first, bucket.static_count);
			case CASTERS_DYNAMIC:
				recorded += self.draw_casters(cmd, mesh, bucket, at, 0, bucket.static_first);
				recorded += self.draw_casters(cmd, mesh, bucket, at, tail_at, bucket.count - tail_at);
			default:
				break;
		}
	}

	return recorded;
}

<*
 One range of one bucket's copies, pushed and drawn.

 @param offset : `Where in the bucket the run starts, counted from Bucket.first.`
 @return `1 if anything was drawn, 0 for an empty run — which is what makes the caller's sum a draw-call count.`
*>
fn uint MeshPass.draw_casters(
	&self, vk::CommandBuffer cmd, GpuMesh* mesh, Bucket bucket, uint at, uint offset, uint count
)
{
	if (count == 0) return 0;

	// The mesh contract exactly as the main pass pushes it, and pointing at the
	// same three buffers. The only field that means something different is the one
	// that is not in here at all: `shaders/shadow.slang` reads
	// `light_view_projection` out of the frame block where `mesh.slang` reads
	// `view_projection`.
	//
	// The instance address carries the run's own offset, for `record`'s reason: the
	// shader reads copy zero of its own slice. It is also what makes a sub-range
	// legal at all — `SV_InstanceID` is relative to what is pushed here.
	MeshPush push = {
		.frame = self.frame_address,
		.instances = self.instance_address + (ulong)(bucket.first + offset) * Instance::size,
		.draw = self.draw_address + (ulong)at * DrawRecord::size,
	};

	// The reflected size, for the reason `record` gives at length: the range
	// declared at pipeline creation and the range pushed here read the same field,
	// so they cannot drift without an edit that hardcodes one of them.
	vk::cmdPushConstants(
		cmd,
		self.shadows.pipeline.layout,
		self.shadows.pipeline.shader.stages,
		0,
		self.shadows.pipeline.shader.push_size,
		&push
	);

	vk::cmdBindIndexBuffer(cmd, mesh.indices.buffer, 0, INDEX_TYPE_UINT32);
	vk::cmdDrawIndexed(cmd, mesh.index_count, count, 0, 0, 0);
	return 1;
}

fn ulong? MeshPass.write_frame_block(&self, Gpu* gpu, uint slot, FrameBlock* frame)
{
	if (self.frame_blocks[slot].buffer == null)
	{
		self.frame_blocks[slot] = gpu.create_dynamic(FrameBlock::size)!;
	}
	self.frame_blocks[slot].upload(frame, FrameBlock::size);
	return self.frame_blocks[slot].address;
}

<*
 Writes this frame's instance array into this slot's buffer, growing it first if
 the scene outgrew it.

 Doubling rather than fitting exactly: a scene that adds one instance a frame
 would otherwise reallocate every frame, and the allocator's free-block reuse
 makes a discarded buffer cheap but not free.
*>
fn ulong? MeshPass.write_instances(&self, Gpu* gpu, uint slot)
{
	sz needed = self.scene.instances.len();

	if (self.instance_capacity[slot] < needed)
	{
		sz capacity = self.instance_capacity[slot] > 0 ? self.instance_capacity[slot] : INITIAL_INSTANCES;
		while (capacity < needed) capacity *= 2;

		// Safe only because this slot's fence has been waited on before recording —
		// see the header. Freeing the *other* slot's buffer here would be a
		// use-after-free the validation layers would not always see.
		if (self.instance_buffers[slot].buffer != null) self.instance_buffers[slot].free();

		self.instance_buffers[slot] = gpu.create_dynamic((sz)(capacity * Instance::size))!;
		self.instance_capacity[slot] = capacity;
	}

	self.instance_buffers[slot].upload(self.scene.instances.entries, (sz)(needed * Instance::size));
	return self.instance_buffers[slot].address;
}

<*
 Copies every spilled material's uniform table into this slot's buffer, and tells
 each one where it landed.

 The whole list rather than the buckets that draw: materials are tens and buckets
 are hundreds, a material can be in several buckets, and the same table would
 then be copied several times. Walking the list is one copy per material per
 frame and gives every material a *stable* offset that `record` can read without
 a second lookup.

 It is copied every frame because `Material.table` is a CPU shadow and this
 buffer is per frame in flight: a script writes a uniform between frames, and the
 GPU may still be executing a frame that reads the other slot's copy. Copying at
 prepare — after the fence wait that owns this slot — is the same discipline the
 instance array has.

 The cost is `sum(table bytes)` of memcpy per frame, which is why
 `MATERIAL_TABLE_BUDGET` bounds a single table.

 Nothing at all when no material spilled, which is the common case and is one
 comparison to find out.
*>
fn void? MeshPass.write_tables(&self, Gpu* gpu, uint slot)
{
	sz wanted = 0;
	foreach (&material : self.materials)
	{
		if (!material.alive) continue;
		material.table_offset = (uint)wanted;
		wanted += material.table.len;
	}
	self.table_address = 0;
	if (wanted == 0) return;

	if (self.table_capacity[slot] < wanted)
	{
		sz capacity = self.table_capacity[slot] > 0 ? self.table_capacity[slot] : 1024;
		while (capacity < wanted) capacity *= 2;
		if (self.table_buffers[slot].buffer != null) self.table_buffers[slot].free();
		self.table_buffers[slot] = gpu.create_dynamic(capacity)!;
		self.table_capacity[slot] = capacity;
	}

	char* into = (char*)self.table_buffers[slot].data();
	foreach (&material : self.materials)
	{
		if (!material.alive || material.table.len == 0) continue;
		mem::copy(&into[material.table_offset], material.table.ptr, material.table.len);
	}
	self.table_address = self.table_buffers[slot].address;
}

<*
 Grows this slot's draw buffer to hold `count` records.
*>
fn void? MeshPass.reserve_draws(&self, Gpu* gpu, uint slot, sz count)
{
	if (self.draw_capacity[slot] >= count) return;

	sz capacity = self.draw_capacity[slot] > 0 ? self.draw_capacity[slot] : INITIAL_INSTANCES;
	while (capacity < count) capacity *= 2;

	if (self.draw_buffers[slot].buffer != null) self.draw_buffers[slot].free();

	self.draw_buffers[slot] = gpu.create_dynamic((sz)(capacity * DrawRecord::size))!;
	self.draw_capacity[slot] = capacity;
}

<*
 Computes this frame's joint matrices for every character posed from its bone
 nodes, and hands back the buffer's address.

 The third of the three pose paths and the expensive one, which is what
 `skeleton: true` buys: the palette is `bone.world * inverse_bind` per joint, read
 off nodes a script may have written between frames — so a look-at, an aim offset
 or a foot planted on a slope moves the skin, none of which a baked table can
 express.

 The CPU computes it rather than a compute shader, and that is not an oversight.
 `Scene.update_world_matrices` has already produced every bone's world matrix by
 the time this runs, so the work here is one 4x4 multiply per joint. Doing it on
 the GPU would mean uploading sixty matrices so the device could turn them into
 sixty matrices — strictly more traffic than uploading the sixty results, plus a
 dispatch and a barrier. `shaders/skin.slang` is where compute earns its place,
 and it is a different question: *where the vertex blend runs*, not *who writes
 the palette*.

 Returns zero when nothing is live, which leaves `FrameBlock.live_poses` null —
 and no instance points at it, because `POSE_LIVE` is only set here.
*>
fn ulong? MeshPass.write_live_poses(&self, Gpu* gpu, uint slot)
{
	// Two passes over the players: one to size the buffer, one to fill it. The
	// alternative is growing while writing, and the addresses handed to instances
	// would be into a buffer that then moved.
	sz needed = 0;
	foreach (&player : self.scene.players)
	{
		if (!player.live_skin) continue;
		Asset* owner = self.assets.slot(player.asset);
		if (owner == null) continue;

		foreach (&target : player.skinned)
		{
			if (target.skin >= owner.skins.len()) continue;
			needed += owner.skins[target.skin].joints.len();
		}
	}
	if (needed == 0) return 0;

	if (self.pose_capacity[slot] < needed)
	{
		sz capacity = self.pose_capacity[slot] > 0 ? self.pose_capacity[slot] : INITIAL_INSTANCES;
		while (capacity < needed) capacity *= 2;

		// Safe only because this slot's fence has been waited on — the same rule the
		// instance and draw buffers are freed under.
		if (self.pose_buffers[slot].buffer != null) self.pose_buffers[slot].free();

		self.pose_buffers[slot] = gpu.create_dynamic((sz)(capacity * Matrix4f::size))!;
		self.pose_capacity[slot] = capacity;
	}

	Matrix4f* palette = (Matrix4f*)self.pose_buffers[slot].data();
	uint at = 0;

	foreach (&player : self.scene.players)
	{
		if (!player.live_skin) continue;
		Asset* owner = self.assets.slot(player.asset);
		if (owner == null) continue;

		foreach (&target : player.skinned)
		{
			if (target.skin >= owner.skins.len()) continue;
			AssetSkin* skin = &owner.skins[target.skin];

			Node* mesh_node = self.scene.node(target.node);
			if (mesh_node == null) continue;

			// The joints are glTF node indices and `targets` is the map from those
			// to this instance's own nodes — built at instantiation, which is the
			// only moment anything knows the correspondence.
			foreach (j, joint : skin.joints)
			{
				Matrix4f pose = matrix::IDENTITY4{float};
				if (joint < player.targets.len())
				{
					Node* bone = self.scene.node(player.targets[joint]);
					// A joint whose node was pruned poses nothing rather than reading
					// a stale matrix: the vertices riding it stay where the bind pose
					// left them, which is local and visible.
					if (bone != null) pose = bone.world.mul(skin.inverse_bind[j]);
				}
				palette[at + j] = pose;
			}

			// Live, and where. The top bit is what the shader selects the buffer on;
			// the rest is this character's slice. Written every frame because the
			// slice moves when the number of live characters does.
			mesh_node.pose = POSE_LIVE | at;
			at += (uint)skin.joints.len();
		}
	}

	return self.pose_buffers[slot].address;
}

<*
 Poses every compute-routed bucket into this frame's output buffer, and barriers
 the result so the vertex stage can read it.

 Recorded before the render pass begins — `MeshPass.prepare` is the phase that
 exists for this, because `vkCmdDispatch` between `vkCmdBeginRendering` and
 `vkCmdEndRendering` is illegal.

 One dispatch per bucket rather than one per character: a bucket already is
 "these copies of this mesh", which is exactly the unit the shader indexes with
 `iid * vertex_count + vid`. A bucket mixing baked and live copies is still one
 dispatch, because which palette a copy reads is decided per instance inside the
 shader.

 One barrier for the whole frame, not one per dispatch. Every dispatch writes a
 disjoint slice of one buffer and no dispatch reads another's, so there is
 nothing to order between them; what has to be ordered is all of them against the
 first vertex shader that reads the buffer, and that is one
 `COMPUTE_SHADER -> VERTEX_SHADER` barrier at the end.

 Does nothing at all — no pipeline compiled, no buffer allocated, no command
 recorded — in a frame with no compute-routed bucket in it.
*>
fn void? MeshPass.skin(&self, Gpu* gpu, vk::CommandBuffer cmd, uint slot)
{
	self.posed_offsets.clear();

	// Sized first, so the buffer cannot move under an address already pushed.
	// `NOT_PRESKINNED` for every bucket that is not routed here, which keeps this
	// list parallel to `Scene.buckets` and lets `record` index it directly.
	sz needed = 0;
	foreach (bucket : self.scene.buckets)
	{
		GpuMesh* mesh = self.assets.mesh(bucket.asset, bucket.mesh);
		if (!bucket.preskinned || mesh == null || !mesh.has_skin)
		{
			self.posed_offsets.push(NOT_PRESKINNED);
			continue;
		}
		self.posed_offsets.push((uint)needed);
		needed += (sz)mesh.vertex_count * (sz)bucket.count;
	}
	if (needed == 0) return;

	// Compiled the first time anything asks. A project that never routes a
	// character through compute never reads `shaders/skin.slang` off disk.
	if (!self.skin_pipeline.ready) self.build_skin_pipeline(gpu)!;

	if (self.posed_capacity[slot] < needed)
	{
		sz capacity = self.posed_capacity[slot] > 0 ? self.posed_capacity[slot] : INITIAL_INSTANCES;
		while (capacity < needed) capacity *= 2;

		// This slot's fence has been waited on, so the GPU is not still reading it —
		// the same rule the instance, draw and pose buffers are grown under.
		if (self.posed_buffers[slot].buffer != null) self.posed_buffers[slot].free();

		// Device-local: written by the GPU and read by the GPU in the same frame, so
		// there is nothing for the CPU to map and no reason to pay for a
		// host-visible heap.
		self.posed_buffers[slot] = gpu.create_device_storage((sz)(capacity * SkinnedVertex::size))!;
		self.posed_capacity[slot] = capacity;
	}

	ulong output_address = self.posed_buffers[slot].address;
	vk::cmdBindPipeline(cmd, PIPELINE_BIND_POINT_COMPUTE, self.skin_pipeline.handle);

	foreach (i, bucket : self.scene.buckets)
	{
		if (self.posed_offsets[i] == NOT_PRESKINNED) continue;

		GpuMesh* mesh = self.assets.mesh(bucket.asset, bucket.mesh);
		if (mesh == null) continue;
		Asset* owner = self.assets.slot(bucket.asset);
		if (owner == null) continue;

		SkinPush push = {
			.positions = mesh.positions.address,
			.normals = mesh.has_normals ? mesh.normals.address : 0,
			.joints = mesh.joints.address,
			.weights = mesh.weights.address,
			// Offset to this bucket's first copy, exactly as the draw path offsets
			// it, so `iid` starts at zero in the shader either way.
			.instances = self.instance_address + (ulong)bucket.first * Instance::size,
			.baked = owner.poses.address,
			.live = self.live_address,
			.output = output_address + (ulong)self.posed_offsets[i] * SkinnedVertex::size,
			.vertex_count = mesh.vertex_count,
			.instance_count = bucket.count,
			.flags = mesh.has_normals ? FLAG_HAS_NORMALS : 0,
		};

		vk::cmdPushConstants(
			cmd,
			self.skin_pipeline.layout,
			SHADER_STAGE_COMPUTE_BIT,
			0,
			self.skin_pipeline.shader.push_size,
			&push
		);

		uint threads = mesh.vertex_count * bucket.count;
		vk::cmdDispatch(cmd, (threads + SKIN_WORKGROUP - 1) / SKIN_WORKGROUP, 1, 1);
	}

	// Everything written above, against everything that reads it below.
	vk::MemoryBarrier2 barrier = {
		.sType = STRUCTURE_TYPE_MEMORY_BARRIER_2,
		.srcStageMask = PIPELINE_STAGE_2_COMPUTE_SHADER_BIT,
		.srcAccessMask = ACCESS_2_SHADER_STORAGE_WRITE_BIT,
		.dstStageMask = PIPELINE_STAGE_2_VERTEX_SHADER_BIT,
		.dstAccessMask = ACCESS_2_SHADER_STORAGE_READ_BIT,
	};
	vk::DependencyInfo dependency = {
		.sType = STRUCTURE_TYPE_DEPENDENCY_INFO,
		.memoryBarrierCount = 1,
		.pMemoryBarriers = &barrier,
	};
	vk::cmdPipelineBarrier2(cmd, &dependency);
}

<*
 Compiles `shaders/skin.slang` and builds the compute pipeline, once.

 Late rather than in `init` for the reason the whole path is opt-in: this is a
 Slang compile and a `VkPipeline` that a project which never asks for compute
 skinning should not pay for.
*>
fn void? MeshPass.build_skin_pipeline(&self, Gpu* gpu)
{
	String source = shader_source("skin.slang", mem)!;
	defer source.free(mem);

	ShaderModule mod = compile_slang(source, "skin.slang", SKIN_ENTRIES[..])!;
	defer mod.free();
	if (!mod.ok)
	{
		io::eprintfn("three: the skinning shader would not compile: %s", mod.diagnostic);
		return SHADER_MISSING_ENTRY_POINT~;
	}

	self.skin_pipeline.init(gpu, &mod)!;
}

<*
 Numbers an agent can read its own cost off. Computed with culling off — see
 `Scene.stats`.

 @param scene : `Which scene to measure, or null for the one being rendered.`
*>
fn SceneStats MeshPass.stats(&self, Scene* scene = null)
{
	if (scene == null) scene = self.scene;
	SceneStats stats = scene.stats(&self.assets);
	// Filled in here rather than by `Scene`, because whether a bucket casts is a
	// property of its material and of the pass — see `casts_shadow`. It is last
	// frame's number, like `culled_last_frame` beside it, and for the same reason:
	// `stats()` is a query and does not record a pass to count.
	stats.shadow_draws = self.shadows.draws;
	stats.shadow_static_draws = self.shadows.static_draws;
	// For the same reason, and it is a fact about right now rather than about last
	// frame: the count is maintained at the two ends of a material's life rather
	// than swept for here.
	stats.materials = self.live_materials;
	// A fact about the pass and not about the scene being asked, which is the
	// point of it: the number exists so that a scene nobody replaced shows up.
	stats.scenes = (uint)self.scenes.len();
	return stats;
}

<*
 Compiles a material from an agent's fragment body.

 The pipeline comes from the same `PipelineCache` the built-in shader uses, keyed
 on the assembled source, so two `ShaderMaterial`s written with identical bodies
 share one `VkPipeline` and the second one skips the Slang call entirely. They
 are still two materials — uniform values are pushed per draw, so two materials
 over one pipeline are two buckets with different bytes.

 The diagnostic is handed back rather than printed: a bad shader has to throw a
 JS error carrying the Slang text. It is set on success too, because a warning
 arrives with `ok == true` and an agent that never sees its warnings writes the
 same mistake twice.

 The blend mode is part of the pipeline and so is decided here, once. It costs no
 extra compile: the cache keys the SPIR-V on the source and the pipeline on the
 render state, so a body written twice — once opaque, once transparent — is one
 Slang call and two `VkPipeline` objects. There is no setter for the same reason.

 @param side : `SIDE_FRONT, SIDE_BACK or SIDE_DOUBLE — which faces survive culling.`
 @param blending : `BLENDING_NONE, BLENDING_NORMAL or BLENDING_ADDITIVE. Baked into the pipeline, so it cannot change afterwards.`
 @param textures : `Samplers the body wants, in declaration order. Declared here and filled afterwards, one set_material_texture per name, because that is where the references are taken.`
 @param vertex : `A void displace(inout Vertex v) body, or empty for a material that does not move its geometry.`
 @param bounds : `How far that body can move a vertex, world units. Grows the box the frustum is tested against — see Material.bounds.`
 @param [out] diagnostic : `Slang's output verbatim, on failure and on warnings alike. Owned by the caller.`
 @return `The material index, for Node.material.`
*>
fn uint? MeshPass.create_material(
	&self,
	Gpu* gpu,
	Target* target,
	String fragment,
	MaterialUniform[] uniforms,
	int side = SIDE_FRONT,
	int blending = BLENDING_NONE,
	MaterialTexture[] textures = {},
	String vertex = "",
	float bounds = 0,
	String* diagnostic = null
)
{
	uint index;
	BlendMode blend = blend_for(blending);
	@pool()
	{
		String source = material_source(fragment, uniforms, tmem, textures, vertex)!;
		MeshPipeline* pipeline = self.pipelines.acquire(
			gpu, target, source, "three.material", state_for_blend(blend), diagnostic
		)!;

		// The reference `acquire` handed out is the material's from here — no
		// retain, because there is no second holder.
		index = self.claim_slot({
			.pipeline = pipeline,
			.cull = cull_for_side(side),
			.blend = blend,
			.fragment = fragment.copy(mem),
			// Copied only when there is one, so a material without a vertex body
			// carries a zero slice rather than a pointer into static memory that
			// `Material.free` would hand to the allocator.
			.vertex = vertex.len > 0 ? vertex.copy(mem) : (String){},
			.bounds = bounds,
			// A `ShaderMaterial` can be given a `map` afterwards like any other
			// material — `material.slang` declares the same binding 0 that
			// `mesh.slang` does, so `Surface.uv` samples it either way. It just does
			// not start with one.
			.texture = NO_TEXTURE,
		});
	};
	return index;
}

<*
 `material.side = ...` — change which faces this material keeps.

 One field, and no pipeline. With the cull mode baked into `PipelineState` a new
 side would mean a new `VkPipeline` built from the material's own source, which
 would need a device, a target, the assembled source read back out of the
 pipeline cache, and a fault path for each of those going wrong.

 Making the cull mode dynamic deletes all of it. `MeshPass.record` sets it per
 bucket from this field, so two sides of one material are one pipeline and this
 is an assignment. See `PipelineState`.

 The built-in materials are refused. `DEFAULT_MATERIAL` is shared by every node
 that was never given a material of its own, so turning its faces round would
 turn every such node's faces round — a scene-wide change made through a handle
 that reads like it names one thing. `LINE_MATERIAL` is refused for a different
 reason: a debug line has no facing to cull, and offering the setting would be
 offering one that does nothing.

 @return? MATERIAL_UNKNOWN : `No such material, or one of the two built-in ones, which are shared.`
*>
fn void? MeshPass.set_material_side(&self, uint index, int side)
{
	Material* material = self.editable(index)!;

	material.cull = cull_for_side(side);
}

<*
 `material.opacity = ...` — how much of what is behind this material shows
 through it.

 Settable, unlike the blend mode beside it, and the difference is the whole shape
 of this file: opacity is *push data*, multiplied into the alpha `record` sends
 with the draw, so changing it costs a float and reaches the next frame. Blending
 is pipeline state, so changing that would cost a pipeline. One is a setter, the
 other a constructor argument, and which is which is decided by the hardware
 rather than by taste.

 It does nothing on a material that is not transparent, and that is stated rather
 than enforced: an opaque pipeline discards the alpha it writes, so the number is
 stored, reported and simply never read. Refusing it would be refusing the order
 a script naturally writes things in, and Three.js behaves the same way.

 Stored as its complement — `Material.one_minus_opacity` has the argument.

 The built-in materials are refused, for `set_material_side`'s reason.

 The range is not checked here. The JS boundary refuses anything outside 0..1 by
 name, which is where a script's mistake can be reported against the line that
 made it; this is the floor under that.

 @return? MATERIAL_UNKNOWN : `No such material, or one of the two built-in ones, which are shared.`
*>
fn void? MeshPass.set_material_opacity(&self, uint index, float opacity)
{
	Material* material = self.editable(index)!;

	material.one_minus_opacity = 1.0f - opacity;
}

<*
 What `material.opacity` reads back as.

 An index that names nothing answers 1.0 rather than faulting, which is
 `material_uv`'s rule: a getter on a disposed handle should say what a material
 that never asked for anything would say, and every material starts opaque.
*>
fn float MeshPass.material_opacity(&self, uint index)
{
	Material* material = self.material(index);
	if (material == null) return 1.0f;
	return material.opacity();
}

<*
 A material that is the built-in shader plus an image —
 `three.MeshLambertMaterial`.

 No Slang, no device, no new pipeline. It borrows one of the pass's own pipelines
 — `self.pipeline` is the very one `DEFAULT_MATERIAL` draws with — so building
 one is a push onto a list and a retain. That is why it is its own verb rather
 than a `ShaderMaterial` with a one-line body: putting a picture on a box should
 not compile a shader, should not be able to fail with a compiler diagnostic, and
 in a build with no Slang could not happen at all.

 That promise is what makes the blend variants prebuilt. A blend mode is a
 pipeline field on this device, so a transparent material needs a different
 `VkPipeline` from an opaque one — and building it here would need the `Gpu` and
 the `Target` this signature does not take, inside whichever frame first said
 `transparent: true`. `MeshPass.init` builds all three up front instead: same
 `mesh.slang`, so no Slang call, about a millisecond each, once, at startup.

 It has no colour of its own, deliberately. `mesh.color` is the per-copy channel
 and `mesh.slang` multiplies it into the sampled texel, so a tinted textured mesh
 already works and a thousand of them are still one draw call. A colour on the
 material would be a second way to say the same thing that also splits the
 bucket.

 The texture is retained here and released by `MeshPass.free` or by
 `set_material_map` pointing this material somewhere else. The reference the
 script's own handle holds is a different one, and `dispose()` drops only that.

 `NO_TEXTURE` is allowed and is not a pointless material: it is the built-in
 shader with a `side` of its own, which is the cheapest possible skydome — a
 sphere seen from inside shows only back faces. A material that wants neither an
 image nor a side should still be `DEFAULT_MATERIAL`, which costs no slot at all.

 @param texture : `An index into Assets.textures, or NO_TEXTURE for the mesh's own image.`
 @param side : `SIDE_FRONT, SIDE_BACK or SIDE_DOUBLE — which faces survive culling.`
 @param blending : `BLENDING_NONE, BLENDING_NORMAL or BLENDING_ADDITIVE. Selects one of the three pipelines built in init; nothing is compiled here whichever it is.`
 @return `The material index, for Node.material.`
 @return? MATERIAL_TEXTURE_UNKNOWN : `No such texture: a disposed handle, or one from another context.`
*>
fn uint? MeshPass.create_texture_material(&self, int texture, int side = SIDE_FRONT, int blending = BLENDING_NONE)
{
	if (texture != NO_TEXTURE && !self.assets.texture_alive(texture)) return MATERIAL_TEXTURE_UNKNOWN~;

	// Retained before the push, so the count says the material names the slot from
	// the first instant it does. A no-op for `NO_TEXTURE`, which names none.
	self.assets.retain_texture(texture);

	BlendMode blend = blend_for(blending);
	MeshPipeline* pipeline = self.pipeline;
	switch (blend)
	{
		case ALPHA: pipeline = self.alpha_pipeline;
		case ADDITIVE: pipeline = self.additive_pipeline;
		case NONE: break;
	}
	// Retained rather than acquired. This borrows a pipeline the pass already holds
	// instead of asking the cache for the built-in shader again — it knows the
	// answer — so the reference has to be taken by hand.
	self.pipelines.retain(pipeline);
	return self.claim_slot({
		.pipeline = pipeline,
		.cull = cull_for_side(side),
		.blend = blend,
		.fragment = "",
		.texture = texture,
	});
}

<*
 `material.repeat` / `material.offset` — how the texture is laid across a
 surface.

 ## Why this is on the material and not on the texture

 Three.js puts `repeat` and `offset` on the `Texture`, and it is a well-known
 trap there: two materials sharing a texture cannot disagree, so the answer is to
 clone the texture. Here it would be worse. Textures are deduplicated by a content
 hash across every file and every `DataTexture`, so a `.png` on disk and the
 identical image inside a `.glb` are deliberately *one* slot — putting a
 transform on that slot would make a brick wall's tiling change because something
 unrelated used the same brick image, with nothing in either script mentioning
 the other.

 On the material it costs nothing extra: `map` already lives there, a material is
 already one bucket, and two surfaces wanting the same image at different
 densities are two materials, which is what they already had to be.

 ## Zero is refused rather than accepted

 A repeat of zero maps every texel of a surface to one point of the texture, so
 it is never what anyone meant — and it is exactly what a struct field left unset
 looks like. `Material.uv_transform_or_identity` reads all-zero as "no
 transform"; this refuses to write one, so the two cannot be confused.

 @param repeat_u : `Times across. Must not be zero.`
 @return? MATERIAL_UNKNOWN : `No such material in this context.`
 @return? MATERIAL_REPEAT_IS_ZERO : `A repeat of zero collapses the surface onto one texel.`
*>
fn void? MeshPass.set_material_uv(&self, uint index, float repeat_u, float repeat_v, float offset_u, float offset_v)
{
	if (index >= self.materials.len()) return MATERIAL_UNKNOWN~;
	if (repeat_u == 0 || repeat_v == 0) return MATERIAL_REPEAT_IS_ZERO~;

	self.materials[index].uv_transform = { repeat_u, repeat_v, offset_u, offset_v };
}

<*
 What `material.repeat` and `material.offset` read back as.
*>
fn float[4] MeshPass.material_uv(&self, uint index)
{
	if (index >= self.materials.len()) return UV_IDENTITY;
	return self.materials[index].uv_transform_or_identity();
}

<*
 `material.map = texture` — point a material at an image, or at `NO_TEXTURE`.

 The built-in materials are refused, for `set_material_side`'s reason and more
 sharply. `DEFAULT_MATERIAL` is what every node draws with until it is given
 something else, so a map set on it would texture the entire scene through a
 handle that reads like it names one material. `LINE_MATERIAL` is refused because
 a debug line carries no uvs, so the setting would silently do nothing.

 A mesh with no uvs is not refused and cannot be, which is the one surprise worth
 stating: `mesh.slang` samples only under `FLAG_HAS_UVS`, so a map on a convex
 hull — which has no natural parameterisation and uploads no uv stream — renders
 exactly as it did without one. The material is not wrong and the texture is not
 missing; there is nowhere on that geometry to put it.

 @param gpu : `For the wait below. Null in a scene-math runtime, which has nothing in flight.`
 @return? MATERIAL_UNKNOWN : `No such material, or one of the two built-in ones, which are shared.`
 @return? MATERIAL_TEXTURE_UNKNOWN : `No such texture.`
*>
fn void? MeshPass.set_material_map(&self, Gpu* gpu, uint index, int texture)
{
	Material* material = self.editable(index)!;
	if (texture != NO_TEXTURE && !self.assets.texture_alive(texture)) return MATERIAL_TEXTURE_UNKNOWN~;
	if (material.texture == texture) return;

	// Retain before release, even though it reads redundant. The two indices can
	// name the same slot — a script can reach one texture through two handles, and
	// both resolve to one entry because the table deduplicates by content — and
	// releasing first would take that entry to zero, destroy the image, and retain
	// a slot that had just been freed.
	if (texture != NO_TEXTURE) self.assets.retain_texture(texture);

	// The old image goes only if nothing else names it, and a frame in flight may
	// still be sampling the one about to be destroyed. `Texture.free` retires it
	// through `gpu/retire.c3` rather than destroying it, which is why there is no
	// stall here: re-pointing a map inside a frame callback costs a list push and
	// two frames of patience.
	self.assets.release_texture(gpu, material.texture);

	material.texture = texture;
}

<*
 `material.textures.<name> = texture` — put an image in one of the sampler
 bindings the body declared.

 `set_material_map` for the bindings above zero, and the differences are all in
 the first line: the binding is found by name, through the shader's own
 reflection, so a script says `noise_map` and never says `1`. `map` keeps its own
 verb because binding 0 is the one binding no agent declared — it is the
 template's, it is what an untextured mesh falls back through, and reaching it by
 the name the template happens to use would make `base_color_map` part of the
 script-facing API.

 The built-in materials are refused, more simply here: neither declares a sampler
 past binding 0, so there is no name that could resolve.

 The retain/release dance is `set_material_map`'s exactly.

 @param name : `The sampler as the body spells it.`
 @param texture : `An index into Assets.textures, or NO_TEXTURE to put white back.`
 @return? MATERIAL_UNKNOWN : `No such material, or one of the two built-in ones.`
 @return? MATERIAL_TEXTURE_UNKNOWN : `No such texture: a disposed handle, or one from another context.`
 @return? MATERIAL_SAMPLER_UNKNOWN : `This material's shader has no sampler by that name.`
*>
fn void? MeshPass.set_material_texture(&self, Gpu* gpu, uint index, String name, int texture)
{
	Material* material = self.editable(index)!;
	if (texture != NO_TEXTURE && !self.assets.texture_alive(texture)) return MATERIAL_TEXTURE_UNKNOWN~;

	uint binding = material.binding_of_texture(name);
	if (binding == 0) return MATERIAL_SAMPLER_UNKNOWN~;

	int held = material.textures.at(binding);
	if (held == texture) return;

	if (texture != NO_TEXTURE) self.assets.retain_texture(texture);
	self.assets.release_texture(gpu, held);

	material.textures.set(binding, texture);
}

<*
 Which texture is in one of a material's own sampler bindings.

 `NO_TEXTURE` for a material that does not exist and for a name that is not one
 of its samplers alike, which is `material_opacity`'s rule: a getter answers what
 a material that was never given anything would answer, and the *setter* is where
 a bad name is reported against the line that wrote it.
*>
fn int MeshPass.material_texture(&self, uint index, String name)
{
	Material* material = self.material(index);
	if (material == null) return NO_TEXTURE;
	return material.textures.at(material.binding_of_texture(name));
}

<*
 `material.dispose()` — give back the script's reference to a material.

 Not a free, and the wording is `texture.dispose()`'s on purpose because the rule
 is the same one. A material is collected when the handle has been given back
 *and* no node still names it. Disposing while a mesh is still drawing with it
 leaves that mesh correct and collects the material when the mesh goes — which is
 what makes this safe to call as soon as a script is done *referring* to the
 material.

 Refusing the call while a node still names it reads stricter and is worse:
 `new three.Scene()` followed by a rebuild is the shape an agent iterating
 actually writes, and under a refusal every one of those runs would have to
 dispose in an order nobody wants to think about.

 The built-in materials are refused, for `set_material_side`'s reason.

 Disposing twice is not an error — the second call has nothing to give back.

 @param gpu : `For the collection this may trigger. Null defers it to the next one that has a device.`
 @return? MATERIAL_UNKNOWN : `No such material, or one of the two built-in ones, which are shared.`
*>
fn void? MeshPass.dispose_material(&self, Gpu* gpu, uint index)
{
	Material* material = self.editable(index)!;
	if (material.released) return;

	material.released = true;
	self.pending_materials++;
	self.collect_materials(gpu);
}

<*
 Frees every material whose handle is gone and which no node names.

 Run from `dispose_material`, which is when the first half becomes true, and from
 `record`, which is the only reliable point at which the *second* half changes:
 nodes die through `Scene.kill` and through `new three.Scene()`, and neither
 tells the pass anything. Guarded on `pending_materials`, so a scene nobody has
 disposed in never walks its nodes for this at all.

 One pass over the nodes rather than one per candidate. The candidates are
 usually one and the nodes are usually thousands.
*>
fn void MeshPass.collect_materials(&self, Gpu* gpu)
{
	if (self.pending_materials == 0) return;

	@pool()
	{
		bool[] named = alloc::new_array(tmem, bool, self.materials.len());
		foreach (&node : self.scene.nodes)
		{
			if (!node.alive) continue;
			if (node.material < named.len) named[node.material] = true;
		}

		foreach (i, &material : self.materials)
		{
			if (!material.alive || !material.released || named[i]) continue;
			self.free_material(gpu, (uint)i);
			self.pending_materials--;
		}
	};
}

<*
 Gives back everything one material holds, and empties its slot.

 The texture first and the pipeline second, which is the order the two tables
 were built in. Both are releases rather than frees: an image several materials
 share outlives this one, and so does a pipeline.
*>
fn void MeshPass.free_material(&self, Gpu* gpu, uint index)
{
	Material* material = &self.materials[index];

	// The same wait `set_material_map` makes, and only when this release is the
	// last one: a frame in flight may still be sampling the image about to be
	// destroyed. The image goes through the deletion queue now, exactly as the
	// pipeline below does.
	//
	// This can land inside a frame, since `record` collects, and that is no longer
	// a reason to be careful: nothing here waits for anything.
	self.assets.release_texture(gpu, material.texture);

	// The agent's own samplers, on the same terms. Walked by binding rather than by
	// the reflected layout, because this runs *after* a shader may have been
	// swapped out from under the material and the slots are the record of what is
	// actually held: a reference is released by whoever took it, not by whoever
	// still declares a name for it.
	for (uint binding = MATERIAL_BINDING_FIRST; binding < MATERIAL_BINDINGS_END; binding++)
	{
		int held = material.textures.at(binding);
		if (held == NO_TEXTURE) continue;
		self.assets.release_texture(gpu, held);
	}

	self.pipelines.release(gpu, material.pipeline);
	material.free();
	// The mirror of `note_material_claimed`, and the only place the count goes
	// down: `dispose_material` is a *release*, and a material a node still names
	// is still live and still holding its pipeline. Counting it out at the dispose
	// would report a scene as having given back what it has not.
	self.live_materials--;
}

fn void MeshPass.free(&self, Gpu* gpu)
{
	for (uint i = 0; i < MAX_FRAMES_IN_FLIGHT; i++)
	{
		if (self.frame_blocks[i].buffer != null) self.frame_blocks[i].free();
		if (self.instance_buffers[i].buffer != null) self.instance_buffers[i].free();
		self.instance_capacity[i] = 0;
		if (self.draw_buffers[i].buffer != null) self.draw_buffers[i].free();
		if (self.table_buffers[i].buffer != null) self.table_buffers[i].free();
		self.table_capacity[i] = 0;
		if (self.pose_buffers[i].buffer != null) self.pose_buffers[i].free();
		if (self.posed_buffers[i].buffer != null) self.posed_buffers[i].free();
		self.draw_capacity[i] = 0;
		self.pose_capacity[i] = 0;
		self.posed_capacity[i] = 0;
	}
	self.skin_pipeline.free(gpu);
	// The device is idle by the time a pass is torn down, so the shadow map's
	// pipeline is destroyed outright rather than retired — see `ShadowMap.free`.
	self.shadows.free(gpu);
	self.posed_offsets.free();
	self.draw_indices.free();
	self.free_scenes();
	// Before `assets.free`, which frees every texture slot outright: releasing
	// afterwards would decrement counts in a freed list. The device is idle by the
	// time a pass is torn down, so no wait is needed here as it is in
	// `set_material_map`.
	//
	// Live slots only. A collected one released its image when it was collected,
	// and `Material.free` leaves `texture` at `NO_TEXTURE` so a second pass here
	// would be a no-op even if this forgot to ask.
	foreach (&material : self.materials)
	{
		if (!material.alive) continue;
		self.assets.release_texture(gpu, material.texture);
		// And the agent's own samplers, on the same terms as `map`. The counts do
		// not survive the next line either way — `assets.free` destroys every slot
		// whatever it is holding — but a teardown that gave back one of a material's
		// five references and not the other four would read as a bug in whichever of
		// the two is looked at second.
		for (uint b = MATERIAL_BINDING_FIRST; b < MATERIAL_BINDINGS_END; b++)
		{
			self.assets.release_texture(gpu, material.textures.at(b));
		}
	}
	self.assets.free(gpu);
	// Before the cache, which owns the pipelines these borrow. No release, unlike
	// `free_material`: `PipelineCache.free` destroys every entry whatever its count
	// says, and routing a teardown through the eviction path would push pipelines
	// into a deletion queue that is about to be drained anyway.
	foreach (&material : self.materials) material.free();
	self.materials.free();
	self.pipelines.free(gpu);
	self.pipeline = null;
	self.line_pipeline = null;
	// The same treatment and for the same reason: these are borrows into a cache
	// that has just destroyed every entry it owned, so there is nothing to give
	// back — only a pointer that must stop looking live.
	self.alpha_pipeline = null;
	self.additive_pipeline = null;
	self.ready = false;
}
