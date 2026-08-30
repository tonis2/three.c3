<*
 The graph root, traversal, the instance table and `stats()`.

 ## The thesis, as code

 An instance is an immutable asset reference plus a transform, and that is what
 makes every scene the API can express optimised by construction.
 `build_draw_list` is where that stops being a claim: a traversal produces one
 `Instance` record per drawn node, records sharing an `(asset, mesh)` key land
 next to each other, and each run of them becomes one `vkCmdDrawIndexed` with an
 instance count. A thousand copies of a wall are a thousand 148-byte transforms
 and one draw. There is no fast path and no batching heuristic — there is no
 other path.

 ## Three passes, and why they are separate

	update_world_matrices   parent-relative TRS -> world matrix, dirty-driven
	build_draw_list         traverse, cull, sort by bucket key, write instances
	MeshPass.record         upload, bind, draw

 The first is the only one that touches the hierarchy, and the only one that can
 be skipped — a scene where nothing moved does not walk at all, which matters
 because a frame asks for it three to five times (see `Scene.matrices_current`).
 The second is rebuilt every frame because culling depends on the camera. The
 third is in `render/pass.c3` and knows nothing about nodes.

 ## Culling is on by default and it changes the numbers

 An instance outside the frustum is dropped from the draw list, so `stats()`
 deliberately does *not* read the last frame's list — it rebuilds with culling
 off, so that "1000 instances is 1 draw call" is a statement about the scene
 rather than about where the camera happened to be pointing.
*>
module three;

import std::collections::list;
import std::sort;
import std::math;
import std::math::vector;
import std::math::matrix;
import std::math::quaternion;
import collision;

<*
 One instance, exactly as the GPU reads it. Mirrored in `shaders/mesh.slang`.

 148 bytes: two `float4x4`, a `float4` and a `uint` under scalar layout, which is
 4-byte aligned, so an array of these is tightly packed and indexable by
 `SV_InstanceID` with no padding rules to get wrong. `normal` carries the inverse
 transpose in its upper 3x3 — see `normal_matrix` for why the model matrix will
 not do.

 ## Why `color` and `variant` are here rather than in the material

 This is the only per-copy channel a draw call has. Everything else a mesh draws
 with — the pipeline, the uniforms, the texture — is bucket state, pushed once for
 the whole `vkCmdDrawIndexed`, so two copies that disagree about any of it are two
 buckets and two draws. These two disagree for free: they are read out of this
 array by `SV_InstanceID`, so a thousand differently coloured copies of one mesh
 stay one draw call. The alternative is two materials, which is two pipelines'
 worth of bucket state.

 `variant` selects a row of the material's uniform table and is nothing at all to
 the default shader. `color` multiplies albedo in both.
*>
struct Instance
{
	Matrix4f model;
	Matrix4f normal;
	// Multiplies albedo. The alpha is carried for a `shade()` body to read; the
	// opaque pipeline does not blend with it.
	float[4] color;
	// Which row of the material's table. Clamped in the shader against the row
	// count the material declared, so a variant past the end is the last row rather
	// than a read off the end of the push block.
	uint variant;
	// Where this copy's joint matrices start, in matrices, with `POSE_LIVE` in the
	// top bit saying which buffer they are in.
	//
	// The field a crowd is affordable because of. A hundred characters mid-stride
	// at a hundred different phases disagree about this one uint and about nothing
	// else, so they key a hundred different frames out of one baked table and stay
	// a single `vkCmdDrawIndexed`. Zero on a mesh with no skin.
	uint pose;
}

<*
 One instanced draw.

 `first` and `count` index `Scene.instances`. The pass hands the shader
 `instances + first * sizeof(Instance)` rather than passing `first` as a push
 constant, so `SV_InstanceID` starts at zero in every bucket and the
 firstInstance-versus-InstanceIndex question never has to be answered.
*>
struct Bucket
{
	AssetId asset;
	uint mesh;
	uint material;
	uint first;
	uint count;

	<*
	 The one node in this bucket, when a soft body writes its vertices, and
	 `NO_NODE` otherwise.

	 The only place a bucket names a node, and it can only exist because a soft
	 bucket holds exactly one copy by construction. `MeshPass.write_soft_vertices`
	 is what reads it: the vertices it writes are per node, and every other field
	 here describes something shared.
	*>
	NodeId node;

	<*
	 How many of `count` the camera can see, and they are the first ones.

	 Two passes read one instance array, and this is the whole of how. The shadow
	 pass draws `[first, first + count)` — every copy that can throw a shadow into
	 the frame — and the colour pass draws `[first, first + visible)`. A copy the
	 camera cannot see but the light can sits in the tail and is rasterised into
	 the map only.

	 It is a prefix and not a mask because `vkCmdDrawIndexed` takes a first and a
	 count: two ranges out of one array means one of them is contiguous from
	 `first`, and the sort puts the visible ones there. See the comparator in
	 `build_draw_list` — the tiebreak sits *after* `preskinned`, so it orders
	 copies within a bucket rather than splitting one in two.

	 Equal to `count` in every frame with no shadow pass.
	*>
	uint visible;

	<*
	 Where this bucket's static casters start, counted from `first`, and how many
	 there are.

	 The second partition of one instance array, and the order is the whole trick.
	 `visible` needs a prefix and the static set needs a run, and two independent
	 halves cannot both be prefixes — so the sort lays a bucket out in four cells:

		[ visible dynamic | visible static | hidden static | hidden dynamic ]
		 <----------- visible ----------->
		                   <--- static_count --->
		                   ^ static_first

	 Visible is still exactly the prefix `record` has always drawn. The static run
	 is contiguous and `record_shadow` draws it alone when rebuilding the cached
	 half of the map. The *dynamic* casters are the two ends, which is the one
	 thing this ordering gives up: a bucket holding both static and hidden dynamic
	 copies costs the dynamic shadow pass two `vkCmdDrawIndexed` instead of one.
	 Movers are the small half by construction, so the split is paid on a handful
	 of buckets — and the alternative was giving up the visible prefix, which every
	 colour draw depends on.

	 With nothing marked static the middle two cells are empty and the layout is
	 `[visible | hidden]`.

	 A pre-skinned bucket is never static: its vertices come out of a buffer the
	 compute pass wrote this frame, indexed from the bucket's own first copy, so
	 "it did not move" cannot be true of one and drawing a sub-range of it would
	 read another copy's posed vertices. `Scene.set_static_caster` refuses there.
	*>
	uint static_first;
	uint static_count;

	<*
	 Whether the compute pass poses these copies before the render pass reads them.

	 Part of what makes two draws two draws. Everything else a bucket keys on is
	 about *what* is drawn; this is about where the vertices are read from, and a
	 pre-skinned copy reads a buffer the compute pass wrote while its neighbour
	 reads the mesh's own stream. They cannot share a `DrawRecord`, so they cannot
	 share a bucket.

	 That is the honest cost of the flag: routing one character of a crowd through
	 compute splits it off into a draw call of its own. It is not a switch to flip
	 on a hundred copies of a zombie.
	*>
	bool preskinned;
}

<*
 What an agent reads its own cost off.

 `draw_calls` and `unique_meshes` are the same number until one mesh can be drawn
 under two materials. `draw_calls` is the bucket count; `unique_meshes` counts
 distinct (asset, mesh) pairs across those buckets, so one mesh drawn under two
 materials is two draws and one mesh.
*>
struct SceneStats
{
	uint draw_calls;
	uint unique_meshes;
	uint instances;
	uint nodes;
	uint triangles;
	uint vertices;
	// How many assets are resident, which is the number a level transition has to
	// bring back down — see `Assets.resident`. Not the size of the asset table: the
	// free list is the difference, and a working unload that grew the table would
	// otherwise read as a leak.
	uint assets;
	uint textures;
	usz texture_bytes;
	<*
	 How many materials a script has built and not yet had collected.

	 Filled in by `MeshPass.stats` rather than here, for `shadow_draws`' reason:
	 materials live on the pass and the graph cannot see them. The two built-in
	 ones are not counted — they are shared, they cannot be disposed, and a floor
	 of 2 on the one number this exists to watch would be noise in front of it.

	 It is `assets` for the other resource that has to be given back by hand. A
	 material holds a `VkPipeline`, `material.dispose()` is what gives it back, and
	 this is how a script finds out whether it is doing that — the same job
	 `stats().assets` does for `unloadUnused`. It falls at the *collection*, not at
	 the dispose: a material a node still names is still holding everything it
	 held.
	*>
	uint materials;
	<*
	 How many drawable nodes are collision geometry.

	 What `object.collides = false` is for, seen from the other side. Every mesh
	 counted here is a box in the spatial index and a box tested by every sweep and
	 every raycast; the ones that are not counted cost a query nothing at all,
	 because `rebuild_query_index` files them out rather than rejecting them.

	 Counted with the index's own predicate — alive, drawable, `collides`, and a
	 mesh with a BVH — rather than read off `QueryIndex.entries`, because the index
	 is built by the first query after an invalidation and a scene that has not
	 asked one yet has no entries. Reading the list would answer 0 for a scene full
	 of walls, which is the wrong kind of wrong for a number whose job is to say
	 "this is bigger than you think".

	 The number to watch when a sweep gets slow. Decoration defaults to collision
	 geometry, so a scene grows this without being asked to, and the gap between
	 this and `nodes` is what a level's author has said out loud.
	*>
	uint colliders;

	<*
	 How many scenes exist right now, including this one.

	 Filled in by `MeshPass.stats` rather than here, for `materials`' reason: the
	 list is on the pass and a scene cannot see it.

	 The number a level transition has to bring back down, and the only thing that
	 says so. `new three.Scene()` shows a new world without freeing the one before
	 it — that is what makes building the next level early possible — so a game
	 that never calls `scene.dispose()` reads as correct in every other number
	 here while holding a node pool, a physics world and a set of asset references
	 per level it has ever shown.
	*>
	uint scenes;
	// From the last `update`, not from this call — `stats()` rebuilds with culling
	// off, so there is nothing to count during it. Zero until the first `update`,
	// and zero again after any `update` made with `Scene.cull` false: nothing was
	// dropped, and reporting the frame before it would be a stale number wearing a
	// live one's name.
	//
	// It means the camera in a shadowed frame too. A frame that built one unculled
	// list for both passes reported 0 here whenever the pass was on — honest, and
	// saying nothing.
	uint culled_last_frame;
	// What the light's box dropped, over the same frame. Copies rejected by *both*
	// frustums, so it is what neither pass drew rather than the difference between
	// the two lists — `Scene.shadow_culled` has why. Zero in a frame with no shadow
	// pass, where there is no second box to be outside of.
	uint shadow_culled_last_frame;

	<*
	 What skinning costs, reported apart from everything else.

	 A design with a live palette would want this to warn about a per-frame upload.
	 This design has no per-frame upload for a baked character — the whole point of
	 it — so the lie would be the other way round, and hiding the cost would tell
	 an agent that a rigged file costs what an unrigged one does.

	 What it actually costs is here: how many draws are skinned, how many copies
	 those cover, and the pose memory that was uploaded once and is held for as
	 long as the assets are. `preskinned_instances` is called out separately
	 because it is the expensive one — a compute-routed copy holds a posed mesh of
	 its own, per frame in flight, and it is the only one of the three paths whose
	 cost grows with the vertex count rather than with the joint count.
	*>
	uint skinned_draws;
	uint skinned_instances;
	uint preskinned_instances;
	usz pose_bytes;

	<*
	 How many draw calls the last shadow pass made, and 0 in a frame that had none.

	 The one number in here that is about the frame rather than about the scene,
	 and it has to be: whether a bucket casts is a property of its material and of
	 the pass, not of the graph, so `Scene` cannot work it out and `MeshPass.stats`
	 fills it in afterwards. It is also the only way a script can see that turning
	 shadows on roughly doubled its draw calls — `draw_calls` counts the scene pass
	 alone.
	*>
	uint shadow_draws;

	<*
	 How many draw calls went into the cached half of the shadow map, and 0 in a
	 frame that did not rebuild it — which is most frames, and is the number worth
	 watching.

	 `shadow_draws` beside it is what the frame paid; this is what the rebuild cost
	 on the frames there was one. A script that sees this stay at zero while a
	 character walks about is seeing the cache work. A script that sees it equal to
	 the caster count every frame has something invalidating it — a camera that has
	 not settled, most likely, or a node marked static that something is still
	 moving.

	 Zero in every frame with no static caster at all, which is a frame with no
	 cached map to rebuild rather than a cheap one.
	*>
	uint shadow_static_draws;

	<*
	 The four blocks of memory the renderer owns, in bytes.

	 `texture_bytes` and `pose_bytes` above were the only memory numbers here, and
	 between them they miss nearly all of it. A 1080p frame is a colour and a depth
	 image before a single mesh is loaded; a post chain is two or three more, at
	 eight bytes a pixel; one `three.light.shadow.size = 4096` is two D32 images
	 and is larger than every other number in this struct put together; and a
	 scene's geometry is on the device *and* kept on the CPU, because
	 `scene/asset.c3` holds the positions and the triangle index for picking.

	 Read off the allocations rather than recomputed from extents and formats, so
	 they cannot drift from what was actually asked of the device.

	 `shadow_bytes` and `geometry_bytes` are filled in by `MeshPass.stats`, which
	 can see the shadow map and the asset table. The other two need the `Renderer`
	 and are filled in by `JsRuntime.scene_stats`; they are zero in a runtime with
	 no device, along with everything else here that needs one.
	*>
	usz shadow_bytes;
	usz target_bytes;
	usz post_bytes;
	usz geometry_bytes;
}

// A drawable node, flattened out of the hierarchy and waiting to be sorted into
// buckets. `key` packs (asset, mesh); `material` is kept beside it rather than
// folded in because `bucket_key` already spends all 64 bits on two full-range
// uints and narrowing either half to make room would be a silent wrap rather
// than an error. Two compares instead of one is the cheaper price.
//
// `order` leads the sort and is the material index for everything that is not
// blended or a line, so consecutive buckets share a pipeline wherever they can —
// which is what keeps the per-bucket `cmdBindPipeline` from thrashing once a
// scene uses more than one material. See `draw_order`.
struct Draw @local
{
	uint material;
	ulong key;
	uint slot;
	// Where this draw sits in the frame — `draw_order`'s answer, not the material
	// index. Computed at push time because the comparator cannot compute it:
	// `quicksort` takes a captureless function pointer, so the sort has no way to
	// reach a table saying which materials are transparent.
	uint order;
	// Signed distance from the near plane to the world-bounds centre, for the
	// back-to-front sort. Zero for an opaque draw, which never pays for it: the
	// blended pipelines write no depth, so ordering is what stands in for the depth
	// buffer, and only the draws that lost the depth buffer need it.
	float depth;
	// Whether the camera can see this copy, as opposed to whether the light can. A
	// draw is in the list if *either* is true; this says which range of its bucket
	// it belongs in. Always true in a frame with no shadow pass.
	bool visible;
	// Whether the compute pass poses this copy. A field beside the key rather than
	// a bit inside it, for `material`'s reason: `bucket_key` spends all 64 bits on
	// two full-range uints, and stealing one would be a silent wrap. It is a
	// tiebreaker in the sort so that copies routed the same way stay adjacent and
	// coalesce.
	bool preskinned;
	// Whether this copy belongs to the half of the shadow map that is drawn once
	// and kept — `Node.static_caster`. Beside `visible` rather than in the key for
	// the same reason `visible` is: it decides where a copy sits inside its bucket,
	// not which bucket it lands in.
	bool is_static;
	// Whether a soft body is writing this copy's vertices. Not a sort key at all,
	// unlike `preskinned`: it does not group copies, it *separates* them — a soft
	// body's vertices are its own, so the coalescing loop opens a bucket for one
	// and closes it again immediately. See `Bucket.node`.
	bool soft;
}

<*
 Where a copy sits inside its bucket: the last key of the sort, and the only one
 that is not about which bucket it lands in.

 Four cells, ordered so the camera-visible copies are a prefix and the static
 casters are a run — see `Bucket.static_first` for the diagram and for why both
 have to be true at once. Everything is cell 0 in a frame with no shadow pass and
 nothing marked static.
*>
fn uint draw_cell(bool visible, bool is_static) @local @inline
{
	if (visible) return is_static ? 1 : 0;
	return is_static ? 2 : 3;
}

struct Scene
{
	List{Node} nodes;
	List{uint} free_slots;
	NodeId root;

	// The asset table this scene's nodes count against, or null. See
	// `attach_assets`.
	Assets* assets;

	// One per instantiated subtree of an asset that has animation clips —
	// `scene/animation.c3`. The first per-instance state that is not a transform,
	// which is why it is a list beside the nodes rather than a field on one: a
	// `Node` is an asset reference plus a matrix, and paying a player's worth of
	// bytes on every node of every scene to animate a dozen of them is the wrong
	// trade.
	List{AnimationPlayer} players;

	// Rebuilt by `update`; read by `MeshPass.record`.
	List{Draw} draws;
	List{Instance} instances;
	List{Bucket} buckets;

	bool cull;
	// The working counter, zeroed at the top of every `build_draw_list`. It is zero
	// for the whole of a `stats()` call, because that call rebuilds with no frustum
	// on purpose — which is why the number `SceneStats` reports is the one below.
	uint culled;
	// What the last `update` culled. Two fields rather than one because the two
	// callers of `build_draw_list` ask different questions: a frame wants to know
	// what the camera dropped, and `stats()` deliberately rebuilds with culling off
	// so its instance count cannot depend on where the camera points. Sharing one
	// field means that rebuild erases the frame's answer on its way past, and the
	// reported number is then zero forever.
	uint culled_last_frame;
	// The same pair again for the *light's* box. Counted only in a frame that has a
	// shadow pass, because in every other frame there is no second frustum and zero
	// is the honest answer.
	//
	// A drawable is in the shadow list unless *both* frustums rejected it, so this
	// counts the copies that are in neither pass — not the difference between the
	// two lists. `culled` above is still "what the camera dropped", and the two
	// overlap by exactly the copies the light kept for its own pass.
	uint shadow_culled;
	uint shadow_culled_last_frame;
	bool started;

	<*
	 Whether every node's `world` is the one its local transform implies.

	 The flag that makes the second and third `update_world_matrices` of a frame
	 free — three to five walks per frame: one for `Scene.bounds`, one for
	 `follow_camera`, one inside `Scene.update`, and more if a script asks for a
	 bounding box. `dirty` already saved the matrix arithmetic on the repeats; it
	 never saved the traversal, the per-node validation or the 64-byte
	 `parent_world` copy per recursion, which is what is left when a scene is
	 standing still.

	 Set in exactly one place and cleared in exactly one place.
	 `update_world_matrices` sets it; `invalidate` clears it, and every mutation
	 that sets a `Node.dirty` anywhere goes through `invalidate` — the setters here,
	 and the three writers outside this file that reach for `Node.dirty` directly
	 (`AnimationPlayer.apply`, `Physics.write_back`, `setTransform` at the JS
	 boundary). The cost of getting it wrong is a node drawn at its previous
	 transform, so `Scene.touch` is what makes a hand-written `node.position = ...`
	 land rather than a nicety.
	*>
	bool matrices_current;

	<*
	 `bounds`, as it last answered, and whether that answer is still good.

	 `Scene.bounds` is exact, not conservative — it transforms every vertex of
	 every drawable node, which measures at 100k–370k vertex transforms on the
	 reference village. It is called once per frame by the shadow fit and a second
	 time per frame by any attached follow camera, for a value that changes only
	 when the scene does.

	 The invalidation is the whole of the risk, and it is stated plainly because a
	 stale box is not a crash: it is a shadow fit around the wrong region and a
	 camera framed on the wrong thing, both of which look like a tuning problem. So
	 the flag is cleared by `invalidate` beside `matrices_current` and by nothing
	 else — the two are invalidated by exactly the same events, because a box over
	 world matrices cannot go stale without a world matrix going stale first.

	 The one thing outside this file that could move it is the asset table: a mesh
	 that finished uploading after the box was taken would have hull positions the
	 box was not fitted around. It cannot happen — `create_slot` retains the mesh it
	 names and retaining is what uploads, so every node in a scene is past that
	 point before the node exists.
	*>
	collision::Aabb3 bounds_box;
	bool bounds_current;

	<*
	 Bumped whenever something a *static* caster contributes to the shadow map
	 could have changed.

	 `render/shadow.c3` keeps a depth image of everything marked
	 `Node.static_caster` and re-rasterises it only when this number moves — see
	 `ShadowMap.static_fit` for the rest of the key. It is deliberately separate
	 from `matrices_current`: a walking character moves every frame and must not
	 cost the village its cached map.

	 Two writers, and the interesting one is the walk. `update_branch` bumps this
	 whenever a static node's world matrix is recomputed, which is the only place
	 that knows a node *actually* moved — a static wall under a dynamic group moves
	 when the group does, and the setter that moved the group was never shown the
	 wall. `invalidate` bumps it for the changes that are not a movement: a node
	 added or removed, a subtree re-parented, a material swapped, a node joining or
	 leaving the static set.

	 Bumped conservatively in both. Over-bumping costs a re-render of the static
	 map and is invisible; under-bumping is a shadow of where a building used to
	 be, which looks like a lighting bug rather than a stale cache.
	*>
	uint static_revision;

	<*
	 The broad phase over drawable nodes — `scene/query.c3`.

	 Beside the two caches above and invalidated by the same call, for the same
	 reason: it is derived from the world matrices and cannot go stale without one
	 of them going stale first. It differs in *when* it is rebuilt — `Scene.bounds`
	 is refreshed by whoever asks and the shadow fit reads it every frame, where
	 this one is rebuilt only by a query. A frame that asks nothing spatial pays
	 nothing for it.
	*>
	QueryIndex query;

	// How many nodes are marked static right now. Maintained by the two writers of
	// `Node.static_caster` and by `kill`, and read by `MeshPass.prepare` to decide
	// whether the light's fit should hold still — see `ShadowMap.fit`'s `stable`. A
	// count rather than a bool because it has to go back down: a scene that marked
	// a wall static and then removed the wall has nothing to cache.
	uint static_nodes;

	<*
	 What names this scene from JavaScript, and it is never reused.

	 A `Scene` in a script is a host scene plus this number. It has to outlive the
	 scene itself: a disposed scene's id must keep answering "no such scene" rather
	 than coming back as somebody else, which is the same argument `NodeId` makes
	 for its generation and the reason this counts up rather than indexing
	 `MeshPass.scenes`.
	*>
	uint id;

	<*
	 This scene's physics world — `scene/physics.c3`.

	 Here rather than on the runtime because a body names a `NodeId`, and the node
	 pool those index into is on this struct. It is what makes a level's bodies
	 survive the switch to it: they are built while the scene is off screen, and
	 `activate` shows a world that is already standing up.

	 **Only the active scene is stepped.** `frame_loop.c3` advances one world per
	 frame, so bodies in a scene nobody is looking at are correct and motionless.
	 Stepping every world would charge a game for the levels it is not playing.
	*>
	Physics physics;

	<*
	 This scene's navigation bake and the flow fields over it — `scene/nav.c3`.

	 Beside `physics` and for its reason, with one difference worth knowing: a bake
	 is CPU voxelization over this scene's own triangles and needs no frame at all,
	 so a scene that is not active bakes exactly as well as one that is. That is
	 the larger half of what owning these buys — the next level's pathfinding can
	 be solved before anybody sees it.
	*>
	NavMesh nav;
	List{NavFieldSlot} nav_fields;

	<*
	 How this scene is lit and what it clears to — see `SceneLook`.

	 Kept here so that `activate()` brings a world back the way it was rather than
	 the way a fresh scene starts. The renderer holds one live copy of each of
	 these, because there is one frame; this is the copy that survives not being
	 the one on screen.
	*>
	SceneLook look;
}

<*
 The look of a scene: the colour it clears to, its light, and its shadows.

 One struct because there is one moment they all change — `activate()` — and a
 switch that carried two of the three would be a bug that only shows in the one
 it forgot.

 What is *not* here is the machine: the assets, the materials, the camera, the
 post chain and the shadow map's image and pipeline all belong to the renderer
 and are reused by whichever scene is on screen. The line is whether two scenes
 could sensibly disagree about it.
*>
struct SceneLook
{
	// `scene.background`, already clamped, with alpha pinned at one —
	// `js_background_set` has why there is no alpha to set.
	float[4] clear;
	// `three.light` and `three.lights`: every light this world is lit by, and the
	// ambient floor under them. The active scene's is the one that shades the
	// frame.
	Lighting lighting;
	// `three.light.shadow`, the five settings and none of the device objects.
	ShadowSettings shadow;
	// `scene.background` when it is an image, and `scene.environment` — see
	// `SkyLook`. Both are counted references and `Scene.free_sky` gives them back.
	SkyLook sky;
}

// What a scene starts on, and what `new three.Scene()` therefore shows: the
// renderer's own defaults, so a script that sets a background and a script that
// does not render the same first frame.
const SceneLook DEFAULT_LOOK = {
	.clear = DEFAULT_CLEAR,
	.lighting = DEFAULT_LIGHTING,
	.shadow = DEFAULT_SHADOW,
	.sky = DEFAULT_SKY,
};

<*
 Where every node generation in the process comes from.

 Global rather than per-slot, and that is what makes more than one scene safe.
 `Scene.node` rejects a handle whose generation disagrees with the slot's — but
 two scenes both starting at zero would have a node 5 generation 0 each, and a
 handle from one would resolve to the other's node with nothing to say so. Drawn
 from here, no two live nodes anywhere share a `(index, generation)` pair, so a
 handle used against the wrong scene fails the check that already exists and
 raises the stale-handle error that is already written.

 Wraps after 2^32 node creations. At that point a handle held across the wrap
 could collide — and only if the same slot index comes back with the same number
 on it, so the wrap is the precondition rather than the failure. It is roughly
 four billion `scene.add()` calls.

 **Widening it is not the cheap fix it looks like.** A handle is two `int`s at
 the JavaScript boundary and the bulk paths hand a script the raw pair as an
 `Int32Array` — `query.handles`, `cast.handles` — which is documented surface a
 script indexes into. A 53-bit generation would fit a double exactly and would
 break every one of those, so the trade is a documented limit against a
 documented format.
*>
uint next_node_generation @local = 1;

// Scene ids, from the same kind of counter and for `Scene.id`'s reason.
uint next_scene_id @local = 1;

<*
 An empty scene with a root node.

 The root is a plain group at the origin, so `scene.add(...)` with no parent
 lands under it and a whole scene can be moved by moving one node.
*>
fn Scene* Scene.init(&self)
{
	// Heap-backed explicitly. A List left zero-initialised has a null allocator and
	// `list_ensure_capacity` resolves null to `tmem`, so the first push backs it
	// with temp-arena memory that any enclosing `@pool()` frees on the way out.
	self.nodes.init(mem, 64);
	self.free_slots.init(mem, 16);
	self.players.init(mem, 4);
	self.draws.init(mem, 64);
	self.instances.init(mem, 64);
	self.buckets.init(mem, 16);
	self.nav_fields.init(mem, 4);

	self.id = next_scene_id++;
	self.look = DEFAULT_LOOK;
	self.cull = true;
	self.started = true;
	self.root = self.create_slot(NO_NODE, NO_ASSET, NO_MESH, "root");
	return self;
}

<*
 Everything derived from the node pool is out of date as of now.

 One function so that there is one list. Three things are cached off the
 hierarchy — the world matrices, the bounding box, and the shadow map's static
 half — and they are invalidated by the same events, so a mutation that
 remembered two of the three would be a bug that only shows up in the one it
 forgot. Adding a fourth cache means adding a line here and nowhere else.

 One of the four is not all-or-nothing. The query index can be told *what* moved
 and re-file that subtree instead of re-filing the scene, so `moved` is how a
 caller says "this change is one subtree and nothing else". Everything that is
 not — an add, a removal, a re-parenting, a node joining or leaving the query set
 — leaves it unset and pays for a rebuild.

 @param node : `The node that changed, or null for a change that is not about one node — an add, a removal, a re-parenting. Only read to decide whether the static half of the shadow map has to be rebuilt; a null is treated as "it might have been static", which is the conservative answer.`
 @param moved : `The id of that node when the change is a movement of its transform and nothing else. NO_NODE otherwise, which drops the query index rather than re-filing.`
*>
fn void Scene.invalidate(&self, Node* node = null, NodeId moved = NO_NODE)
{
	self.matrices_current = false;
	self.bounds_current = false;
	if (moved.is_set())
	{
		self.query.note_moved(moved);
	}
	else
	{
		self.query.drop();
	}
	if (node == null || node.static_caster) self.static_revision++;
}

<*
 Marks a node's local transform as changed from outside the setters.

 Three callers write `Node.position` and friends directly and then set
 `Node.dirty` — `AnimationPlayer.apply`, `Physics.write_back`, and `setTransform`
 at the JS boundary — because each already has the node resolved and the setters
 would cost a second lookup per channel, per frame, per body. They call this
 instead of writing the flag, so the caches in `invalidate` are not something a
 fourth such caller has to know about.

 `Scene.touch` is the same thing for a script that wrote the fields itself.
*>
fn void Scene.mark_moved(&self, NodeId id)
{
	Node* node = self.node(id);
	if (node == null) return;
	node.dirty = true;
	// The id as well as the pointer, and that is what the handle is for: it is what
	// lets the query index re-file this subtree instead of the scene.
	self.invalidate(node, id);
}

<*
 Points this scene at the asset table its nodes reference.

 This is where `Asset.refs` comes from. Every place a node can start naming an
 asset is `create_slot` and every place it can stop is `kill`, so counting there
 means there is one implementation of the count rather than one per caller —
 which matters because being wrong by one means either a leak or a freed buffer.

 Detached by default and a no-op then. A scene with no asset table is the
 scene-math test configuration: there is no device, nothing is uploaded, and
 there is nothing to count.

 The pointer is into the `MeshPass` that owns both, so a pass must not be copied
 after `init`.
*>
fn void Scene.attach_assets(&self, Assets* assets)
{
	self.assets = assets;
}

<*
 Forgets the player rooted at `id`, if there is one.

 Called from `kill` for every node of a removed subtree, so it has to be cheap
 for the overwhelmingly common case of "this node roots nothing". The shift
 `remove_at` does is over a list with one entry per animated prop in the scene.
*>
fn void Scene.drop_player(&self, NodeId root)
{
	foreach (i, &candidate : self.players)
	{
		if (candidate.root != root) continue;
		candidate.free();
		self.players.remove_at(i);
		return;
	}
}

<*
 The animation player for an instantiated subtree, or null.

 Looked up by the subtree's root, which is the handle `instantiate` returned and
 the thing a script has in hand when it calls `play`. A linear scan because the
 list holds one entry per *animated prop in the scene* — a dozen, not a thousand
 — and a map keyed by `NodeId` would cost more to maintain than the scan costs to
 run.
*>
fn AnimationPlayer* Scene.player(&self, NodeId root)
{
	foreach (&candidate : self.players)
	{
		if (candidate.root == root) return candidate;
	}
	return null;
}

<*
 Frees the whole scene, the physics world and the nav bake with it.

 The two of those are the reason this is not just a list of lists: a collider is
 one heap allocation per body and a bake is a voxel grid, and neither is reachable
 from anywhere else once the scene is gone. `scene.dispose()` from a script ends
 here.
*>
fn void Scene.free(&self)
{
	// The asset references first, through the same `kill` every other way out of a
	// scene goes through — `Scene.attach_assets` has why there is only one. Freeing
	// the node list without this drops the count silently, and the file the scene
	// was holding stays resident for the life of the process with nothing naming
	// it: a `scene.dispose()` that frees the graph and not the geometry.
	if (self.started) self.remove(self.root);
	self.physics.close();
	self.drop_nav();
	self.nav_fields.free();
	foreach (&node : self.nodes)
	{
		node.children.free();
		if (node.name.len > 0) node.name.free(mem);
	}
	self.nodes.free();
	self.free_slots.free();
	foreach (&player : self.players) player.free();
	self.players.free();
	self.draws.free();
	self.instances.free();
	self.buckets.free();
	self.query.free();
	*self = { };
}

// ============================================================================
// The hierarchy
// ============================================================================

<*
 Resolves a handle.

 @return `The node, or null if the id is stale: the slot was freed and possibly reused. Valid only until the next add, which may reallocate the pool.`
*>
fn Node* Scene.node(&self, NodeId id)
{
	if (!id.is_set() || id.index >= self.nodes.len()) return null;
	Node* node = &self.nodes[id.index];
	if (!node.alive || node.generation != id.generation) return null;
	return node;
}

<*
 Adds a group: a node that is traversed and transformed but never drawn.

 @param parent : `NO_NODE for the scene root.`
*>
fn NodeId Scene.add_group(&self, NodeId parent = NO_NODE, String name = "")
{
	return self.attach(parent, NO_ASSET, NO_MESH, name);
}

<*
 Adds a mesh: an asset reference plus a transform, which is the whole of what an
 instance is.

 @param asset : `A handle from Assets.load, primitive or convex.`
 @param mesh : `Index into that asset's meshes.`
*>
fn NodeId Scene.add_mesh(&self, AssetId asset, uint mesh, NodeId parent = NO_NODE, String name = "")
{
	return self.attach(parent, asset, mesh, name);
}

<*
 Places an asset's node hierarchy under `parent`, transforms and all.

 This is Three.js's `gltf.scene`. Without it the loader flattens the file and
 drops every mesh at the origin, so a file that bakes its transforms into the
 vertices renders correctly and one that positions its pieces by node does not —
 a distinction nothing in the API could express, so nothing in the suite could
 catch.

 What a glTF node becomes is `Assets.flatten`'s decision, not this function's.
 JavaScript's `asset.instantiate()` reads the same walk and builds `Object3D`s
 from it, and the two producing different trees for one file would be a bug
 nobody would think to look for.

 The references take care of themselves: every drawing node goes through
 `create_slot`, which retains the asset. So a prop instantiated twice is two
 subtrees over one upload, and dropping one subtree releases exactly its own
 references. Nothing here counts anything.

 @return `The group everything was placed under, or NO_NODE if the handle names no asset.`
*>
fn NodeId Scene.instantiate(&self, AssetId asset, NodeId parent = NO_NODE, String name = "", bool skeleton = false, bool compute_skin = false)
{
	if (self.assets == null) return NO_NODE;
	Asset* loaded = self.assets.slot(asset);
	if (loaded == null) return NO_NODE;

	NodeId group = self.add_group(parent, name.len > 0 ? name : basename(loaded.path));

	List{PlacedNode} placed;
	placed.init(mem, 16);
	defer placed.free();
	self.assets.flatten(asset, &placed, skeleton);

	// Parents precede their children in the walk, so `created` always has the entry
	// a child needs by the time the child is reached. One pass, no fixups.
	List{NodeId} created;
	created.init(mem, placed.len() + 1);
	defer created.free();

	foreach (&entry : placed)
	{
		NodeId into = entry.parent < 0 ? group : created[entry.parent];
		NodeId id = entry.mesh < 0
			? self.add_group(into, entry.name)
			: self.add_mesh(asset, (uint)entry.mesh, into, entry.name);

		Node* node = self.node(id);
		node.position = entry.position;
		node.rotation = entry.rotation;
		node.scale = entry.scale;
		// White unless the file instanced this copy and gave it a `_COLOR_0`.
		// Written unconditionally rather than only when it differs: `add_mesh`
		// already left it white, so the branch would save an assignment and cost a
		// comparison.
		node.color = entry.color;
		// The rest pose, which is a baked frame like any other — so this node draws
		// correctly before anything is played and needs no branch to.
		self.set_skin(id, entry.skin);
		// Routed per character, and it splits this copy off into a draw call of its
		// own — `Node.preskinned` has the argument.
		node.preskinned = compute_skin && entry.skin >= 0;
		node.dirty = true;

		created.push(id);
	}

	// A character whose skeleton was materialised is posed *from* that skeleton —
	// which is what makes the flag worth having, and what it costs. See
	// `AnimationPlayer.live_skin`.
	self.start_player(asset, group, placed.array_view(), created.array_view(), skeleton);
	return group;
}

<*
 Tells a node which skin poses it, and points it at that skin's rest pose.

 The one place `Node.skin` and `Node.pose` are set together, because they are one
 fact: a node with a skin and no offset reads matrix zero of whatever buffer it
 finds, and a node with an offset and no skin is culled against the wrong box.
 Two callers set them — `instantiate` here and `bindSkin` from JavaScript — and
 both go through this rather than writing the fields.

 `-1` clears both, which is what a node that is not a character wants and what a
 recycled slot is reset to.

 The rest offset is only known once the poses are baked, and the bake happens at
 upload — which has already run by the time a node exists, because creating a
 drawing node retains the asset and retaining is what uploads. A skin that failed
 to bake leaves the offset at zero, and zero of a buffer that is not there reads
 as no skin at all.
*>
fn void Scene.set_skin(&self, NodeId id, int skin)
{
	Node* node = self.node(id);
	if (node == null) return;

	node.skin = -1;
	node.pose = 0;
	// A character cannot be a static caster — `set_static_caster` refuses one, and
	// this is the other door: a node may be given a skin *after* it was marked
	// static, and a pose offset moving is a silhouette moving with no transform to
	// notice it.
	if (node.static_caster)
	{
		node.static_caster = false;
		self.static_nodes--;
		self.static_revision++;
	}
	if (skin < 0 || self.assets == null) return;

	Asset* owner = self.assets.slot(node.asset);
	if (owner == null || skin >= owner.skins.len()) return;

	node.skin = skin;
	node.pose = owner.skins[skin].rest_offset;
}

<*
 Every skinned node in a subtree, for the player that will pose them.

 Recursive over a freshly instantiated character, which is two nodes deep in the
 pruned case and a rig deep in the other — the same depth argument
 `Assets.flatten_node` makes.
*>
fn void Scene.collect_skinned(&self, NodeId id, List{SkinnedTarget}* out)
{
	Node* node = self.node(id);
	if (node == null) return;

	if (node.skin >= 0) out.push({ .node = id, .skin = (uint)node.skin });

	// By index: `out.push` cannot move the node pool, but the recursion re-reads
	// `self.node`, and holding a `Node*` across it is the habit worth not having.
	sz children = node.children.len();
	for (sz i = 0; i < children; i++)
	{
		self.collect_skinned(self.node(id).children[i], out);
	}
}

<*
 Gives a freshly instantiated subtree its animation player, if the asset has
 anything to play.

 The map from glTF node index to `NodeId` can only be built here: `flatten`
 carries the glTF index on each entry and this walk is the only thing that knows
 what each entry became. Nothing else has both halves, which is why this is not a
 method on `Assets`.

 A player is created even though nothing is playing. The alternative is building
 the map on the first `play`, which would mean walking the tree a second time —
 and `play` is called from an animation callback, where a hidden tree walk shows
 up as a stutter the first time a character moves.

 Nothing happens for an asset with no clips, so a scene of ten thousand crates
 holds no players at all.
*>
fn void Scene.start_player(&self, AssetId asset, NodeId root, PlacedNode[] placed, NodeId[] created, bool live_skin = false)
{
	List{uint} sources;
	List{NodeId} nodes;
	sources.init(mem, placed.len);
	nodes.init(mem, placed.len);
	defer sources.free();
	defer nodes.free();

	foreach (i, &entry : placed)
	{
		if (entry.gltf_node < 0) continue;
		sources.push((uint)entry.gltf_node);
		nodes.push(created[i]);
	}

	self.bind_player(asset, root, sources.array_view(), nodes.array_view(), live_skin);
}

<*
 Gives a subtree an animation player from a map somebody else built.

 Two callers, arriving from opposite directions. `start_player` above has just
 walked `Assets.flatten` and knows which entry became which node.
 `asset.instantiate()` in JavaScript built the same tree as `Object3D`s and let
 the ordinary `add` path materialize them — so the host never saw the walk, and
 JavaScript is the only thing that knows the correspondence. Both end up here,
 which is why this takes the map as two plain arrays.

 Replaces an existing player on the same root rather than adding a second: two
 players over one subtree would both write to the same nodes every frame, and
 which one won would depend on list order.

 @param gltf_nodes : `The glTF node index each node came from, one per entry and the same length as the node array.`
*>
fn void Scene.bind_player(&self, AssetId asset, NodeId root, uint[] gltf_nodes, NodeId[] nodes, bool live_skin = false)
{
	if (self.assets == null) return;
	Asset* loaded = self.assets.slot(asset);
	// Skins count as something to play. A rigged character with no clips still
	// needs a player, because a player is what holds the map from the file's joint
	// nodes to this instance's — which is what the live palette is computed
	// through. Without this a `skeleton: true` character with no animation would
	// have bones a script could move and nothing that read them.
	if (loaded == null || (loaded.clips.len() == 0 && loaded.skins.len() == 0)) return;

	self.drop_player(root);

	AnimationPlayer player = {
		.root = root,
		.asset = asset,
		.clip = -1,
		.speed = 1,
		.live_skin = live_skin && loaded.skins.len() > 0,
	};
	player.targets.init(mem, loaded.nodes.len());
	for (sz i = 0; i < loaded.nodes.len(); i++) player.targets.push(NO_NODE);

	foreach (i, source : gltf_nodes)
	{
		if (i >= nodes.len) break;
		if (source >= player.targets.len()) continue;
		player.targets[source] = nodes[i];
	}

	// The skinned meshes, found once here rather than searched for per frame.
	//
	// A walk of the subtree rather than of `nodes`, because `nodes` is the channel
	// map and only covers entries that came from a glTF node. A mesh with several
	// primitives becomes one child per primitive with no glTF node of its own —
	// `PlacedNode.gltf_node` is -1 for exactly those — and every one of them is
	// skinned. Scanning the map would pose the first primitive of a character and
	// leave the rest in their bind pose.
	player.skinned.init(mem, 1);
	self.collect_skinned(root, &player.skinned);

	self.players.push(player);
}

<*
 Starts a clip on an instantiated subtree.

 The clip's curves are read here rather than at load — `Assets.ensure_clip`, and
 the rule one level up: a file describes itself cheaply and pays when it is used.
 A character with eleven clips reads the one that plays.

 The instance is posed immediately, before any frame is stepped, so a prop placed
 and played in the same breath looks like its first frame rather than like its
 rest pose for one frame.

 @param speed : `A multiplier on time. Negative plays backwards, and a non-looping clip run backwards stops at its start.`
 @param time : `Seconds into the clip to start at, measured from its own start. What a crowd needs: a hundred characters playing one walk cycle at a hundred phases is a hundred different values of this and one baked clip.`
 @return `False if the subtree has no player or the asset has no clip by that name, which is a question rather than an error — mesh.animations is where the list lives.`
*>
fn bool Scene.play(&self, NodeId root, String clip, bool loop = true, float speed = 1.0f, float time = 0)
{
	if (self.assets == null) return false;
	AnimationPlayer* player = self.player(root);
	if (player == null) return false;

	Asset* loaded = self.assets.slot(player.asset);
	if (loaded == null) return false;

	int found = -1;
	foreach (i, &candidate : loaded.clips)
	{
		if (candidate.name == clip) { found = (int)i; break; }
	}
	if (found < 0) return false;

	self.assets.ensure_clip(player.asset, (uint)found);

	player.clip = found;
	player.speed = speed;
	player.loop = loop;
	player.playing = true;
	player.time = self.assets.slot(player.asset).clips[found].start + time;
	// A phase past the end wraps rather than being refused, so a crowd can be
	// spread with `i / count * duration` and not have to know the duration.
	if (loop) player.time = (float)clip_loop_time(&self.assets.slot(player.asset).clips[found], player.time);

	player.apply(self, &self.assets.slot(player.asset).clips[found]);
	// And the skin, for `apply`'s own reason one level down: a character placed and
	// played in the same breath should be posed at the frame it asked for rather
	// than sitting in its bind pose until something steps the clock.
	player.key_pose(self, self.assets.slot(player.asset), &self.assets.slot(player.asset).clips[found]);
	return true;
}

<*
 Stops a clip where it is.

 Deliberately not a rewind: a character that stops mid-stride and snaps to its
 rest pose is the thing `stop()` is usually reached for to *prevent*. Playing
 something else is how you leave the pose.
*>
fn bool Scene.stop(&self, NodeId root)
{
	AnimationPlayer* player = self.player(root);
	if (player == null) return false;
	player.playing = false;
	return true;
}

<*
 Advances every playing clip by `dt` seconds.

 Runs in the host frame *before* the animation callback, so a callback can read
 where a character got to, and so animation runs with no `setAnimationLoop`
 registered at all.

 @return `Whether anything is still playing, which the sleep condition in main.c3 has to know or the window sleeps in the middle of a walk cycle.`
*>
fn bool Scene.step_animations(&self, float dt)
{
	if (self.assets == null) return false;

	bool playing = false;
	foreach (&player : self.players)
	{
		player.advance(self, self.assets, dt);
		if (player.playing) playing = true;
	}
	return playing;
}

<*
 Whether any clip is playing, without stepping anything.

 The same question `step_animations` answers, asked by a frame that has not
 stepped yet — the sleep condition is evaluated after the step, but a caller
 deciding whether to *start* a frame needs it before.
*>
fn bool Scene.is_animating(&self)
{
	foreach (&player : self.players)
	{
		if (player.playing) return true;
	}
	return false;
}

<*
 The file name out of a path, for naming the group an instantiation lands in.

 A group called `props/crate.glb` is not wrong, only unreadable in a hierarchy
 dump; `crate.glb` is what a `console.log` of a scene wants to show.
*>
fn String basename(String path) @local
{
	usz start = 0;
	foreach (i, c : path)
	{
		if (c == '/' || c == '\\') start = (usz)i + 1;
	}
	return path[start..];
}

fn NodeId Scene.attach(&self, NodeId parent, AssetId asset, uint mesh, String name)
{
	if (!self.started) self.init();

	NodeId use_parent = parent.is_set() ? parent : self.root;
	if (self.node(use_parent) == null) use_parent = self.root;

	NodeId id = self.create_slot(use_parent, asset, mesh, name);
	if (use_parent.is_set())
	{
		// Re-resolved *after* create_slot, which may have grown the pool and
		// invalidated every Node* taken before it.
		Node* parent_node = self.node(use_parent);
		if (parent_node != null) parent_node.children.push(id);
	}
	return id;
}

fn NodeId Scene.create_slot(&self, NodeId parent, AssetId asset, uint mesh, String name)
{
	uint index;
	if (self.free_slots.len() > 0)
	{
		index = self.free_slots.pop()!!;
	}
	else
	{
		index = (uint)self.nodes.len();
		Node fresh;
		fresh.children.init(mem, 4);
		self.nodes.push(fresh);
	}

	Node* node = &self.nodes[index];

	// Everything but `children`: the child list is reused rather than freed and
	// rebuilt. The generation is not reused either — it comes from
	// `next_node_generation`, so a recycled slot gets a number no live node
	// anywhere has, which is what makes a handle from another scene fail rather
	// than resolve.
	uint generation = next_node_generation++;
	node.children.clear();

	node.name = name.len > 0 ? name.copy(mem) : "";
	node.position = { 0, 0, 0 };
	node.rotation = NO_ROTATION;
	node.scale = { 1, 1, 1 };
	node.parent = parent;
	node.world = matrix::IDENTITY4{float};
	node.normal = matrix::IDENTITY4{float};
	node.asset = asset;
	node.mesh = mesh;
	// Reset like everything else here, and for a sharper reason: this slot may have
	// belonged to a node with a `ShaderMaterial`, and a new node inheriting it
	// would draw with a stranger's shader.
	node.material = DEFAULT_MATERIAL;
	// White and row zero: the identity for both channels, so a node that never
	// touches them draws exactly as it did before they existed. Reset here for
	// `material`'s reason.
	node.color = { 1, 1, 1, 1 };
	node.variant = 0;
	// Unskinned until somebody says otherwise, and reset for `material`'s reason: a
	// recycled slot that kept a skin would pose a new node's mesh by a stranger's
	// skeleton, reading joint matrices out of an asset it does not name.
	node.skin = -1;
	node.pose = 0;
	node.preskinned = false;
	// Dynamic until a script says otherwise, and reset for `material`'s reason: a
	// recycled slot that stayed static would put a new node into a shadow map
	// nothing is going to rebuild.
	node.static_caster = false;
	node.visible = true;
	node.world_visible = true;
	// Reset for `material`'s reason: a recycled slot that stayed non-colliding
	// would put a new node into the scene that nothing can sweep against.
	node.collides = true;
	node.dirty = true;
	node.generation = generation;
	node.alive = true;

	// One of the two halves of `Asset.refs` — see `attach_assets`. Counted after
	// the slot is fully written, so a table that somehow reads back into the scene
	// sees a consistent node.
	if (self.assets != null && asset.is_set()) self.assets.retain(asset, mesh);

	// A fresh slot is dynamic — `static_caster` was reset a few lines up — so the
	// static map does not have to be rebuilt for it. It is invalidated here all the
	// same, because a node that is *about* to be marked static arrives through this
	// door and `set_static_caster` bumps the revision itself.
	self.invalidate(node);

	return { .index = index, .generation = generation };
}

<*
 Removes a node and everything under it.

 Removing the root empties the scene but keeps the root itself, so a `Scene` is
 never left without somewhere to add to.
*>
fn void Scene.remove(&self, NodeId id)
{
	Node* node = self.node(id);
	if (node == null) return;

	if (id == self.root)
	{
		// Copy first: killing a child mutates `children` under the iteration.
		NodeId[] children = node.children.to_tarray();
		foreach (child : children) self.kill(child);
		node.children.clear();
		return;
	}

	NodeId parent = node.parent;
	Node* parent_node = self.node(parent);
	if (parent_node != null)
	{
		foreach (i, sibling : parent_node.children)
		{
			if (sibling == id)
			{
				parent_node.children.remove_at(i);
				break;
			}
		}
	}
	self.kill(id);
}

fn void Scene.kill(&self, NodeId id)
{
	Node* node = self.node(id);
	if (node == null) return;

	NodeId[] children = node.children.to_tarray();
	foreach (child : children) self.kill(child);

	// Re-resolved: `to_tarray` allocated, and the recursion above touched the pool
	// through `self`.
	node = self.node(id);
	if (node == null) return;

	// The other half of `Asset.refs`. Every path out of the scene ends here —
	// `remove`, `Scene.remove(root)` for `new three.Scene()`, and the recursion
	// above for a whole subtree — so there is nowhere else a reference can be
	// dropped from.
	if (self.assets != null && node.asset.is_set()) self.assets.release(node.asset, node.mesh);

	// An instantiated subtree's player goes with the subtree's root. Guarded on the
	// list being non-empty rather than searched unconditionally, because `kill`
	// runs once per node of every removal and almost no scene has players at all.
	if (self.players.len() > 0) self.drop_player(id);

	if (node.name.len > 0) node.name.free(mem);
	node.name = "";
	node.children.clear();
	node.alive = false;
	// Before the flag is cleared, so a static caster's removal is seen as one.
	self.invalidate(node);
	if (node.static_caster) self.static_nodes--;
	node.static_caster = false;

	// `alive` is what makes every outstanding id to this slot stale from here, and
	// the fresh number `create_slot` draws is what keeps it stale once the slot is
	// reused. Nothing to bump.
	self.free_slots.push(id.index);
}

<*
 Re-parents, keeping the node's *local* transform.

 Three.js's `add` does the same and it is worth being explicit about: the object
 does not stay where it was on screen, it stays where it was relative to its new
 parent. Preserving world position is a different operation and does not exist
 yet.
*>
fn void Scene.set_parent(&self, NodeId id, NodeId parent)
{
	if (id == self.root) return;
	Node* node = self.node(id);
	if (node == null) return;

	NodeId target = parent.is_set() ? parent : self.root;
	if (self.node(target) == null) return;
	if (target == id) return;

	// A cycle would make `update_branch` recur until the stack runs out, and the
	// stack running out is a much worse error message than nothing happening.
	NodeId walk = target;
	while (walk.is_set())
	{
		if (walk == id) return;
		Node* step = self.node(walk);
		if (step == null) break;
		walk = step.parent;
	}

	Node* old_parent = self.node(node.parent);
	if (old_parent != null)
	{
		foreach (i, sibling : old_parent.children)
		{
			if (sibling == id)
			{
				old_parent.children.remove_at(i);
				break;
			}
		}
	}

	node = self.node(id);
	node.parent = target;
	node.dirty = true;
	self.node(target).children.push(id);
	// Null rather than `node`: a re-parenting moves the whole subtree, and a
	// dynamic node can carry static children.
	self.invalidate();
}

// The transform setters. Each marks the node dirty; `update_world_matrices`
// carries that down to every descendant. Mutating `Scene.node(id).position`
// directly is legal and faster in a loop, but then `touch` is not optional.
fn void Scene.set_position(&self, NodeId id, Vec3 position)
{
	Node* node = self.node(id);
	if (node == null) return;
	node.position = position;
	self.mark_moved(id);
}

<*
 Euler angles in, quaternion stored. `node.c3`'s header has the why; the order is
 XYZ, Three.js's default.
*>
fn void Scene.set_rotation(&self, NodeId id, Vec3 rotation)
{
	Node* node = self.node(id);
	if (node == null) return;
	node.rotation = quat_from_euler(rotation);
	self.mark_moved(id);
}

<*
 A rotation that did not come from Euler angles: a glTF node's TRS, or a sampled
 animation channel.

 Normalized on the way in rather than trusted. A file may store a quaternion that
 has drifted, and `to_matrix` normalizes anyway — doing it here means the node's
 own value is the one everything else reads back, instead of a nearly-unit
 quaternion that produces a correct matrix and a wrong slerp.
*>
fn void Scene.set_quaternion(&self, NodeId id, Quaternionf rotation)
{
	Node* node = self.node(id);
	if (node == null) return;
	node.rotation = rotation.normalize();
	self.mark_moved(id);
}

fn void Scene.set_scale(&self, NodeId id, Vec3 scale)
{
	Node* node = self.node(id);
	if (node == null) return;
	node.scale = scale;
	self.mark_moved(id);
}

<*
 Hides or shows this node, and everything under it.

 This does not dirty the node and does not touch the query index. `query_node`
 tests `world_visible` when it *answers*, which is what makes toggling visibility
 free — routing this through `mark_moved` instead throws the index away on every
 call, measured on eleven characters hiding themselves around each sweep at
 32.7 ms a fixed step against 5.9 ms.

 The reason that looks necessary is that `world_visible` is resolved in the
 world-matrix walk, so the only obvious way to propagate a change is to make the
 walk run. `propagate_visible` does that one job directly instead. Nothing else
 about the node changed: the transform is where it was, so the matrices, the
 bounds and every entry's box are all still correct.

 What does still have to be said is the shadow map's static half, and only when
 the subtree actually contains a static caster — a hidden wall casts no shadow,
 and that image is cached until something bumps the revision.
*>
fn void Scene.set_visible(&self, NodeId id, bool visible)
{
	Node* node = self.node(id);
	if (node == null || node.visible == visible) return;
	node.visible = visible;

	// The parent's *resolved* visibility, so hiding a node under a hidden group is
	// the no-op it should be. A missing parent is the root's case.
	Node* parent = self.node(node.parent);
	self.propagate_visible(id, parent == null || parent.world_visible);
}

<*
 Carries a resolved visibility down a subtree.

 The half of `update_branch` that is about visibility, on its own, so a change to
 `visible` costs the subtree rather than the world-matrix walk and the caches
 hanging off it. Written unconditionally rather than stopping where the value
 already agrees: the walk is a bool store per node — hiding a whole four-hundred-
 node scene is cheaper than one query-index rebuild — and an early exit would
 have to reason about the one node whose `world_visible` is seeded optimistically
 by `create_slot`.

 Recursive and reading children through `self.nodes` for `update_branch`'s
 reasons; nothing may add or remove a node during it.
*>
fn void Scene.propagate_visible(&self, NodeId id, bool parent_visible)
{
	Node* node = self.node(id);
	if (node == null) return;

	bool now = parent_visible && node.visible;
	if (node.static_caster && node.world_visible != now) self.static_revision++;
	node.world_visible = now;

	sz count = node.children.len();
	for (sz i = 0; i < count; i++) self.propagate_visible(self.nodes[id.index].children[i], now);
}

<*
 Whether this node is swept against, and by every spatial query with it.

 `Node.collides` has the argument. Off means the mesh is drawn and is not in the
 query index at all, so it costs a sweep nothing rather than being rejected by
 one — the difference between a pickup and a hundred grass tufts.

 The whole index is dropped, because this decides membership rather than an
 answer. That is the cost of the flag and the reason it is an authoring property:
 a script toggling it per frame is asking for the rebuild `set_visible` above no
 longer pays.
*>
fn void Scene.set_collides(&self, NodeId id, bool collides)
{
	Node* node = self.node(id);
	if (node == null || node.collides == collides) return;
	node.collides = collides;
	self.query.drop();
}

<*
 Draws this node with a different material.

 No `dirty` flag, unlike `set_visible` and the transform setters. Those three
 feed the world-matrix walk, which caches its result; the material feeds the
 bucket key, and `build_draw_list` throws the whole draw list away and rebuilds
 it from scratch every frame.

 The index is not validated here — `Scene` has no view of `MeshPass.materials`,
 and reaching for one would put the render pass inside the scene graph. The JS
 verb validates before it calls, and `MeshPass.record` skips a bucket whose
 material does not resolve.
*>
fn void Scene.set_material(&self, NodeId id, uint material)
{
	Node* node = self.node(id);
	if (node == null) return;
	node.material = material;
	// Not `mark_moved`: nothing about the node's transform changed and the world
	// box is where it was. What *can* change is whether this copy casts at all —
	// `MeshPass.casts_shadow` reads the material's blend mode — so a static caster
	// changing material is a static map to rebuild.
	if (node.static_caster) self.static_revision++;
}

<*
 Puts this node in the half of the shadow map that is drawn once and kept.

 In a village the sun does not move and the buildings do not move, and the shadow
 pass would otherwise rasterise every one of them into an image identical to the
 previous frame's. This is the per-node bool that partitions the casters, and it
 comes with the promise that it does not split a draw bucket — the flag orders
 copies *within* a bucket rather than keying one, so a wall marked static and its
 neighbour that is not are still one `vkCmdDrawIndexed` in the colour pass.

 What it costs to be wrong: a node marked static that then moves leaves its old
 silhouette baked into the cached map until something else invalidates it. Moving
 one through the setters here is safe — they bump the revision — so the failure
 needs a transform written by hand with no `touch`, which is the same failure
 that already draws the node in the wrong place.

 Refused on anything with a skin. A skinned node's silhouette is not its
 transform: it is `Node.pose`, an offset into a palette that
 `AnimationPlayer.key_pose` rewrites without touching a transform at all, and a
 compute-routed copy's vertices live in a buffer the dispatch refills every
 frame. Neither is something the setters here can see move, so "it does not move"
 cannot be made true of a character.

 @return `Whether the node is static now. False for a handle that names nothing and for a skinned node, which is a refusal rather than an error — see above.`
*>
fn bool Scene.set_static_caster(&self, NodeId id, bool value)
{
	Node* node = self.node(id);
	if (node == null) return false;
	bool wanted = value && node.skin < 0 && !node.preskinned;
	if (node.static_caster == wanted) return wanted;
	// Bumped whichever way it went: a node joining the static set has to be drawn
	// into the map, and one leaving it has to be taken out.
	node.static_caster = wanted;
	if (wanted) { self.static_nodes++; } else { self.static_nodes--; }
	self.static_revision++;
	return wanted;
}

<*
 Tints one copy, without costing a draw call.

 Neither this nor `set_variant` marks the node dirty: `dirty` drives the
 world-matrix walk, and these two are copied into the instance record on every
 `build_draw_list` regardless. Marking it would be a wasted subtree traversal per
 colour change, which for a script recolouring a thousand nodes is a thousand of
 them.

 @param color : `sRGB rgb and an alpha - the components a colour picker gives, not linear ones. The shaders decode it before it multiplies albedo, so 0xff8040 renders as 0xff8040 under a full light; see gpu/color.c3. The alpha reaches shade() untransferred - coverage is not a colour - and is still not blended with.`
*>
fn void Scene.set_color(&self, NodeId id, float[4] color)
{
	Node* node = self.node(id);
	if (node == null) return;
	node.color = color;
}

<*
 Points one copy at a row of its material's table.

 Not validated against the material here, and deliberately: a node may be given a
 variant before it is given the material that gives the number meaning, and the
 shader clamps against the row count it was compiled with — so the failure mode
 is the last row rather than a refusal at the wrong moment.
*>
fn void Scene.set_variant(&self, NodeId id, uint variant)
{
	Node* node = self.node(id);
	if (node == null) return;
	node.variant = variant;
}

<*
 Renames a node.

 The scene owns every name — `create_slot` copies what it is given and `kill`
 frees it — so this frees the old one before taking a copy of the new. Anything
 else would either leak on every rename or leave `Scene.free` freeing a string
 that came from somewhere else.
*>
fn void Scene.set_name(&self, NodeId id, String name)
{
	Node* node = self.node(id);
	if (node == null) return;
	if (node.name.len > 0) node.name.free(mem);
	node.name = name.len > 0 ? name.copy(mem) : "";
}

<*
 Says that this node's local transform was written by hand.

 Not optional. Writing `scene.node(id).position` directly and letting the next
 walk notice happens to work only while `update_world_matrices` re-descends the
 whole tree every time; it does not — see `Scene.matrices_current` — so a
 hand-written transform that is not touched is a node drawn where it used to be.
*>
fn void Scene.touch(&self, NodeId id)
{
	self.mark_moved(id);
}

<*
 Runs `#body` for every alive node under `id`, depth first, with the node's id
 and a pointer to it.

 The pointer is invalid the moment anything is added, so a traversal that creates
 nodes has to collect ids first and add afterwards.
*>
macro Scene.@traverse(&self, NodeId id; @body(NodeId child_id, Node* node))
{
	NodeId[] stack_seed = { id };
	List{NodeId} stack;
	stack.tinit(32);
	stack.push_all(stack_seed[..]);

	while (stack.len() > 0)
	{
		NodeId current = stack.pop()!!;
		Node* node = self.node(current);
		if (node == null) continue;
		@body(current, node);
		foreach (child : node.children) stack.push(child);
	}
}

// ============================================================================
// World matrices
// ============================================================================

<*
 Recomputes the world matrix of every node whose local transform changed, and of
 everything below it.

 Depth-first and recursive: a scene deep enough to overflow the stack is a scene
 with tens of thousands of levels of parenting, which is not a shape this API
 encourages. Nothing may add or remove a node during the walk — `node.children`
 is iterated in place.
*>
fn void Scene.update_world_matrices(&self)
{
	// The repeat is free. A frame walks this three to five times —
	// `Scene.bounds` for the shadow fit, `follow_camera`, `Scene.update`, and once
	// more for every bounding box a script asks for — and `Node.dirty` only ever
	// saved the arithmetic, never the walk. See `Scene.matrices_current` for what
	// has to hold for this line to be safe.
	if (self.matrices_current) return;
	if (!self.root.is_set()) return;
	self.update_branch(self.root, matrix::IDENTITY4{float}, true, false);
	self.matrices_current = true;
}

fn void Scene.update_branch(&self, NodeId id, Matrix4f parent_world, bool parent_visible, bool parent_changed)
{
	Node* node = self.node(id);
	if (node == null) return;

	bool changed = parent_changed || node.dirty;
	if (changed)
	{
		Vec3 before = { node.world.m[12], node.world.m[13], node.world.m[14] };
		node.world = parent_world * node.local_matrix();
		node.normal = normal_matrix(node.world);
		if (node.had_world)
		{
			node.prev_world = before;
		}
		else
		{
			node.prev_world = { node.world.m[12], node.world.m[13], node.world.m[14] };
			node.had_world = true;
		}
		node.dirty = false;
		// Where the cached shadow map is really invalidated, and it is here rather
		// than in the setters because this is the only place that knows a node
		// *actually* moved. A static wall parented to a dynamic group is the case
		// that makes the difference: the setter was handed the group, which is not
		// static, so nothing there would have said anything — and the wall's world
		// matrix changed all the same. `changed` carries down the tree, so asking
		// here catches the whole subtree of every move.
		if (node.static_caster) self.static_revision++;
	}

	node.world_visible = parent_visible && node.visible;

	// Copied out before recursing: the children list is walked by index because
	// `self.node` inside the recursion may not reallocate, but reading through a
	// pointer taken before a call that takes `&self` is exactly the habit that
	// stops being safe the day something does.
	Matrix4f world = node.world;
	bool visible = node.world_visible;
	sz count = node.children.len();
	for (sz i = 0; i < count; i++)
	{
		NodeId child = self.nodes[id.index].children[i];
		self.update_branch(child, world, visible, changed);
	}
}

// ============================================================================
// Culling
// ============================================================================

struct Plane
{
	Vec3 normal;
	float distance;
}

struct Frustum
{
	Plane[6] planes;
}

<*
 The six clip planes of a view-projection matrix (Gribb & Hartmann).

 The near plane is row 2 alone rather than `w + z` because this projection is the
 Vulkan/D3D [0,1] depth convention, not OpenGL's [-1,1]. Using the OpenGL form
 culls nothing that should be culled and is invisible until something far away
 disappears.

 `gpu/target.c3`'s negative-height viewport does not enter into this: it flips Y
 in the viewport transform, after clipping, so the planes derived from the matrix
 are the ones the hardware will actually use.
*>
fn Frustum frustum_of(Matrix4f m)
{
	float[<16>] v = m.m;
	// Rows of a column-major matrix.
	float[<4>] r0 = { v[0], v[4], v[8], v[12] };
	float[<4>] r1 = { v[1], v[5], v[9], v[13] };
	float[<4>] r2 = { v[2], v[6], v[10], v[14] };
	float[<4>] r3 = { v[3], v[7], v[11], v[15] };

	Frustum frustum;
	frustum.planes[0] = plane_of(r3 + r0); // left
	frustum.planes[1] = plane_of(r3 - r0); // right
	frustum.planes[2] = plane_of(r3 + r1); // bottom
	frustum.planes[3] = plane_of(r3 - r1); // top
	frustum.planes[4] = plane_of(r2); // near
	frustum.planes[5] = plane_of(r3 - r2); // far
	return frustum;
}

fn Plane plane_of(float[<4>] v) @local
{
	Vec3 normal = { v[0], v[1], v[2] };
	float length = normal.length();
	// A degenerate plane accepts everything rather than rejecting everything: a
	// cull that hides the scene is far worse than a cull that does nothing.
	if (length < 1e-8f) return { .normal = { 0, 0, 0 }, .distance = 1.0f };
	return { .normal = normal / length, .distance = v[3] / length };
}

<*
 Is any part of `box` on the inside of every plane?

 The "positive vertex" test: only the box corner furthest along each plane's
 normal has to be checked, because if that one is behind the plane they all are.
 False positives are possible near the corners of the frustum and are harmless —
 they cost a draw, not a wrong picture.
*>
fn bool Frustum.contains(&self, collision::Aabb3 box)
{
	foreach (&plane : self.planes)
	{
		Vec3 positive = {
			plane.normal.x >= 0 ? box.max.x : box.min.x,
			plane.normal.y >= 0 ? box.max.y : box.min.y,
			plane.normal.z >= 0 ? box.max.z : box.min.z,
		};
		if (plane.normal.dot(positive) + plane.distance < 0) return false;
	}
	return true;
}

<*
 The tight world-space box of one mesh under one transform.

 ## Why this is not `Aabb3.transform_matrix`

 `transform_matrix` re-bounds a *box*: it takes the mesh's local AABB, rotates
 its extent and takes the axis-aligned hull of the result. That is exact only
 when the shape genuinely fills its box, or when the rotation is a multiple of 90
 degrees — and it is conservative rather than wrong, which is why it stays in the
 places that want conservative: frustum culling, the ray broad phase, and the
 shadow-map fit.

 It is the wrong answer for *measuring*, and the failure is sharp rather than
 marginal. `ConeGeometry(1, 1, 4)` is a square pyramid whose base sits corner-on
 to the axes; turn it 45 degrees, which is exactly what makes it a hip roof, and
 re-bounding the box reports a half-extent of 1.414 where the truth is 0.707.
 Doubled. A church full of that shape at that angle reported a minimum z of -49
 for a spire that stops at -45.8.

 That number is not merely reported: `align`, `alignTo`, `frameAll` and
 `BoxHelper` all place things with it, so `align('y', 'min', 0)` on a rotated
 pyramid floats the piece half a unit off the ground — and the helper drawn to
 check it agrees, because it is reading the same wrong box.

 So this bounds the transformed *vertices*. `hull_positions` is every position
 the mesh has, kept on the CPU for picking, so the pass is exact and needs
 nothing uploaded or cached.

 ## The fallback

 `hull_positions` is filled by `upload_primitive`, so a mesh that has not been
 uploaded has nothing to bound but its local AABB. This returns the conservative
 box in that case rather than pretending to an exactness it does not have.

 Every node in a scene is past that point: `Scene.create_slot` retains the mesh
 it names, `Assets.retain` calls `ensure_uploaded`, and `boundingBox()` throws
 unless the object is in a scene. So the fallback covers a device-less runtime
 and an upload that failed and was swallowed — the two states in which a
 wrong-but-valid box beats no box — and not a state a script can put an object
 into and then measure.

 That matters because the alternative would have been to force an upload here,
 and `frame_camera` runs at startup — so measuring would pull every mesh in a
 file onto the device at load, which is exactly what
 `measuring_a_loaded_mesh_does_not_upload_it` exists to prevent.
*>
fn collision::Aabb3 world_mesh_bounds(Matrix4f m, GpuMesh* mesh)
{
	if (mesh.hull_positions.len == 0) return mesh.bounds.transform_matrix(m);

	float[<16>] v = m.m;
	collision::Aabb3 box;
	foreach (i, p : mesh.hull_positions)
	{
		Vec3 world = {
			v[0] * p.x + v[4] * p.y + v[8] * p.z + v[12],
			v[1] * p.x + v[5] * p.y + v[9] * p.z + v[13],
			v[2] * p.x + v[6] * p.y + v[10] * p.z + v[14],
		};
		if (i == 0)
		{
			box = { .min = world, .max = world };
		}
		else
		{
			box.expand_by_point(world);
		}
	}
	return box;
}

// ============================================================================
// The instance table
// ============================================================================

<*
 Brings the world matrices up to date and rebuilds the draw list for a camera.

 The near plane goes in whether or not culling is on, and the two uses of the
 frustum are worth separating because they are different questions. Culling asks
 whether a box is inside six planes and is a performance choice a script can turn
 off; the depth sort asks how far along the view direction a transparent draw
 sits, and turning that off would not make the frame faster, it would make it
 wrong. So `self.cull` gates the frustum pointer and nothing else.

 @param view_projection : `What the frustum and the near plane are derived from. Culling is skipped entirely when Scene.cull is false; the near plane is passed regardless.`
 @param transparent : `One bool per material index — whether that material blends. Empty means an entirely opaque frame, which is what every caller but MeshPass.record passes.`
 @param light_view_projection : `The light's clip matrix when a shadow pass will read this draw list, null otherwise. Its frustum keeps casters the camera cannot see — but as a second test beside the camera's rather than instead of it, so both passes get a cull.`
*>
fn void Scene.update(
	&self,
	Assets* assets,
	Matrix4f view_projection,
	bool[] transparent = {},
	float[] margins = {},
	Matrix4f* light_view_projection = null
)
{
	self.update_world_matrices();
	Frustum frustum = frustum_of(view_projection);
	// Two frustums, and `cull` gates only the camera's. A script turning culling
	// off is asking for its own draws not to be dropped; it is not asking the
	// shadow pass to rasterise the far side of the level, and a light box smaller
	// than the scene would then be the only thing keeping the map affordable.
	//
	// Neither turns the *sort* off: `frustum.planes[4]` is the near plane and a
	// transparent draw is ordered by it whether or not anything was culled.
	Frustum light;
	if (light_view_projection != null) light = frustum_of(*light_view_projection);
	self.build_draw_list(
		assets,
		self.cull ? &frustum : null,
		transparent,
		&frustum.planes[4],
		margins,
		light_view_projection != null ? &light : null
	);
	// Promoted here rather than inside `build_draw_list`, because this call is what
	// "a frame happened" means and the other caller is a query. Assigned
	// unconditionally: with `cull` off nothing was dropped and zero is the honest
	// answer, where holding the previous number would report a camera that has
	// stopped being consulted.
	self.culled_last_frame = self.culled;
	self.shadow_culled_last_frame = self.shadow_culled;
}

// ----------------------------------------------------------------------------

<*
 Where every transparent draw sits, whatever material it names.

 One band above every opaque material and one below the lines. A real material
 index colliding with it would need four billion materials in one context, which
 is several orders of magnitude past the point at which the `List{Material}`
 holding them stopped fitting in memory.
*>
const uint TRANSPARENT_ORDER = 0xfffffffe;

<*
 Where a material sits in the frame, as opposed to what its index is.

 Identity everywhere except two bands at the top. The line material sorts last
 however low its index is: `LINE_MATERIAL` is 1 — it has to be a small number,
 because it is built before any script can ask for a material and indices are
 handed out in order — and 1 would otherwise put every debug line *underneath*
 the scene it is drawn to explain.

 That would not look like an ordering bug. `LINE_STATE` writes no depth and tests
 none, so a line drawn first is painted over by the next opaque triangle and
 vanishes — which reads as "the helper did not work".

 Transparency takes the band just below it, and the two decisions are the same
 decision made twice. A blended pipeline writes no depth either, so a transparent
 draw recorded before an opaque one behind it is overwritten rather than blended
 with, and glass drawn before its own wall shows the clear colour through it.
 Lines stay above transparency deliberately: a debug helper is drawn to be
 *seen*.

 @param transparent : `Whether this material blends — MeshPass.record's table, not something Scene can work out for itself.`
*>
fn uint draw_order(uint material, bool transparent) @local
{
	if (material == LINE_MATERIAL) return 0xffffffffu;
	return transparent ? TRANSPARENT_ORDER : material;
}

<*
 Flattens, culls, sorts by bucket key, and writes one `Instance` per drawn node.

 The sort is what makes the bucketing exact rather than approximate: after it,
 every node sharing an `(asset, mesh)` key is contiguous, so a single linear scan
 produces the buckets and there is no map, no hash and no per-bucket allocation.
 It also means the cost is `n log n` in *instances* rather than anything in
 unique meshes — a scene of ten thousand distinct meshes buckets as cheaply as a
 scene of one repeated ten thousand times.

 @param transparent : `One bool per material index — whether that material blends. Empty is an opaque frame, and is what stats() passes.`
 @param near : `The camera's near plane, for the back-to-front sort. Null means no sort, which is stats()' configuration: a query has no camera to sort by.`
 @param light : `The light's frustum when a shadow pass will read this list, null otherwise. A draw kept by this and not by the camera goes into the tail of its bucket — see Bucket.visible.`
 @param counts_only : `Build the buckets and leave the instance array empty — stats()' configuration, and nothing a frame may pass. See Scene.stats.`
*>
fn void Scene.build_draw_list(
	&self,
	Assets* assets,
	Frustum* frustum,
	bool[] transparent = {},
	Plane* near = null,
	// Indexed by material, exactly as `transparent` is, and empty when nobody has
	// asked for one.
	float[] margins = {},
	Frustum* light = null,
	bool counts_only = false
)
{
	self.draws.clear();
	self.instances.clear();
	self.buckets.clear();
	self.culled = 0;
	self.shadow_culled = 0;

	foreach (slot, &node : self.nodes)
	{
		if (!node.alive || !node.world_visible) continue;
		if (!node.asset.is_set() || node.mesh == NO_MESH) continue;

		GpuMesh* mesh = assets.mesh(node.asset, node.mesh);
		if (mesh == null) continue;
		// Described but not on the device, which means an upload that failed: a node
		// cannot exist without having retained the mesh, and retaining is what
		// uploads. It draws nothing, the same answer a material whose texture would
		// not decode gets.
		if (!mesh.uploaded) continue;

		// Read before the bounds because it decides whether the bounds are needed at
		// all. An index past the end of the table is opaque: the table is exactly as
		// long as `MeshPass.materials`, so past its end is an index that resolves to
		// nothing and draws nothing anyway.
		bool is_transparent = node.material < transparent.len && transparent[node.material];

		// Free in a scene with no soft body in it, which is nearly every scene —
		// `Physics.soft_for` returns on an empty list before it looks at anything.
		NodeId id = { (uint)slot, node.generation };
		SoftMesh* soft = self.physics.soft_for(id);

		// The world box has two readers and neither wants it unconditionally: the
		// frustum test wants it when culling is on, and a transparent draw wants its
		// centre for the depth sort whether culling is on or not. Computed once for
		// both, and not at all in the case that has to stay free — an opaque draw in
		// an unculled frame.
		//
		// Conservative on purpose, unlike the measuring paths. A box that is too big
		// keeps a draw that could have been skipped; a box that is too small drops
		// geometry the camera can see. `world_mesh_bounds` would be tighter and
		// would cost a pass over every vertex of every node every frame to save a
		// handful of draws. The same slack is harmless in the sort: it moves a
		// centre, and sorting centres is already an approximation.
		float depth = 0;
		bool sorted = is_transparent && near != null;
		// True until something rejects it, which is what makes an unculled frame
		// cost nothing: with no frustum and no light there is no box to compute and
		// no test to run.
		bool visible = true;
		if (frustum != null || light != null || sorted)
		{
			// A skinned node is measured by the poses it can reach, not by the pose
			// it was authored in. The bake unioned every joint matrix of every frame
			// over the bind box, and using `mesh.bounds` instead would cull a
			// character the moment an animation took a limb outside the box the
			// modeller drew around the rest pose — which looks like a character that
			// vanishes at certain camera angles during certain frames.
			collision::Aabb3 local = mesh.bounds;
			if (node.skin >= 0)
			{
				Asset* owner = assets.slot(node.asset);
				if (owner != null && owner.pose_matrices > 0) local = owner.skinned_bounds;
			}
			// A soft body is not the shape it was modelled as, and the mesh's own
			// bounds describe the shape it stopped being. The box the solver
			// measured this frame is the one it is actually drawn at.
			if (soft != null) local = soft.bounds;
			collision::Aabb3 box = local.transform_matrix(node.world);

			// A material with a vertex body draws geometry its own bounds do not
			// contain, and the box is what the frustum is asked about — so the
			// material says how far it moves things and the box grows by that much.
			// Grown in *world* units after the transform rather than in object units
			// before it, because the displacement in a body is world-space too:
			// `v.position + something` is metres of scene, whatever the node is
			// scaled by.
			//
			// Zero for every material that has no vertex body, so the common case
			// adds one compare and no arithmetic.
			if (node.material < margins.len && margins[node.material] > 0)
			{
				float m = margins[node.material];
				box = { .min = box.min - {m, m, m}, .max = box.max + {m, m, m} };
			}
			visible = frustum == null || frustum.contains(box);
			if (!visible) self.culled++;

			// The second test, and the reason a draw can survive the first rejection.
			// A caster the camera cannot see still throws a shadow into the frame, so
			// the light's box gets its own say — but only for geometry that will
			// actually be rasterised into the map. A blended material casts nothing
			// (`MeshPass.casts_shadow`), so keeping a transparent draw the camera
			// rejected would put an instance in the array neither pass will read.
			if (!visible)
			{
				bool casts = light != null && !is_transparent && light.contains(box);
				if (!casts)
				{
					if (light != null) self.shadow_culled++;
					continue;
				}
			}
			// Signed distance to the near plane: positive in front of the camera and
			// larger the further away, so "farthest first" is a descending sort with
			// no camera position anywhere in it.
			if (sorted) depth = near.normal.dot(box.center()) + near.distance;
		}

		self.draws.push({
			.material = node.material,
			.key = bucket_key(node.asset.index, node.mesh),
			.slot = (uint)slot,
			.order = draw_order(node.material, is_transparent),
			.depth = depth,
			.visible = visible,
			.preskinned = node.preskinned && node.skin >= 0,
			.is_static = node.static_caster,
			.soft = soft != null,
		});
	}

	if (self.draws.len() == 0) return;

	// Sorted emit, not a permutation of finished buckets. This one sort puts the
	// draws in the order they will be recorded in, and the coalescing loop below is
	// exactly the loop it was before transparency existed: it walks the sorted list
	// and opens a bucket wherever (key, material) changes. So adjacent transparent
	// draws sharing both still fuse into one instanced bucket, and depth-interleaved
	// ones split into more — a wall of glass panes seen edge-on is one draw, and the
	// same panes with something else woven between them is several. That cost is
	// three.js's too, whose per-object sort splits the same way; the alternative is
	// sorting buckets after the fact, which cannot order two panes that landed in
	// the same bucket.
	//
	// `order` and `depth` were computed at push time because this comparator is a
	// captureless function pointer — see `Draw`.
	//
	// Merge, not quick, and the reason is this data. `std::sort::quicksort` pivots
	// on `list[l]` with no median-of-three and no three-way partition, so a run of
	// elements the comparator calls equal peels exactly one element per pass: a run
	// of *k* costs *k²/2*. This list is the worst input that shape has — a few
	// thousand draws over as many distinct keys as there are buckets, which is nine
	// in the reference village, pushed in node-slot order and so already ascending
	// whenever a script places one asset at a time. Measured on 4178 draws in 9
	// buckets: 8.7M comparisons and 20.4 ms against mergesort's 24.9k and 0.196 ms,
	// for the same answer element for element.
	//
	// Being stable is the second reason: draws the comparator cannot separate keep
	// their slot order, so a bucket's instances land in the same sequence every
	// frame instead of in whatever order a partition happened to leave.
	mergesort(self.draws.array_view(), fn int(Draw a, Draw b) {
		if (a.order < b.order) return -1;
		if (a.order > b.order) return 1;
		// Farthest first, and only within the transparent band: everything else is
		// depth-tested and depth-written, so its order is the hardware's business
		// and sorting it would only scatter the pipeline binds. Material and key
		// break the tie so draws at equal depth still coalesce.
		if (a.order == TRANSPARENT_ORDER)
		{
			if (a.depth > b.depth) return -1;
			if (a.depth < b.depth) return 1;
			if (a.material < b.material) return -1;
			if (a.material > b.material) return 1;
		}
		if (a.key < b.key) return -1;
		if (a.key > b.key) return 1;
		// Last but one, and only so that copies routed through compute sit beside
		// each other: they cannot share a bucket with copies that are not, and
		// interleaving them would make four draws out of two.
		if (a.preskinned != b.preskinned) return a.preskinned ? 1 : -1;
		// Last, and the position is the whole design. Every key above this one
		// decides which bucket a draw lands in; this one decides where it sits
		// *inside* that bucket, so a bucket stays one bucket and its camera-visible
		// copies are a prefix of it. Move this above `key` and every mesh with a
		// partly-visible set of copies becomes two draw calls.
		uint cell_a = draw_cell(a.visible, a.is_static);
		uint cell_b = draw_cell(b.visible, b.is_static);
		if (cell_a != cell_b) return cell_a < cell_b ? -1 : 1;
		return 0;
	});

	// Deliberately not equal to the first draw, so the first iteration always opens
	// a bucket. `open_material` is part of that sentinel: two materials over one
	// mesh are adjacent in the sort and share a key.
	ulong open = self.draws[0].key + 1;
	uint open_material = self.draws[0].material;
	bool open_preskinned = self.draws[0].preskinned;
	// Whether the bucket standing open belongs to a soft body. One of the two
	// halves of "a soft copy never shares": this one closes the bucket a soft
	// draw opened, and the `draw.soft` test below is what opens it.
	bool open_soft = false;
	// Where the next copy goes, counted rather than read off `self.instances`,
	// because in a counting build there is no instance array to read it off. The two
	// are the same number in every build that writes one.
	uint placed = 0;
	foreach (draw : self.draws)
	{
		Node* node = &self.nodes[draw.slot];
		// `draw.soft || open_soft` rather than a key comparison, and it is not a
		// tiebreak the sort could do: two soft copies of one mesh agree about every
		// key there is and still cannot share, because each one's vertices are its
		// own buffer. So a soft draw always opens a bucket, and always closes it
		// behind itself.
		if (draw.key != open || draw.material != open_material || draw.preskinned != open_preskinned
			|| draw.soft || open_soft)
		{
			open = draw.key;
			open_material = draw.material;
			open_preskinned = draw.preskinned;
			open_soft = draw.soft;
			// Read off the node rather than unpacked from the key, which only carries
			// the slot index. Every node in a bucket names the same live asset, so
			// any of them supplies the generation.
			self.buckets.push({
				.asset = node.asset,
				.mesh = node.mesh,
				.material = draw.material,
				.first = placed,
				.count = 0,
				.visible = 0,
				.static_first = 0,
				.static_count = 0,
				.preskinned = draw.preskinned,
				.node = draw.soft ? (NodeId) { draw.slot, node.generation } : NO_NODE,
			});
		}

		if (!counts_only)
		{
			self.instances.push({
				.model = node.world,
				.normal = node.normal,
				.color = node.color,
				.variant = node.variant,
				// The whole of what a hundred characters at a hundred phases disagree
				// about. Zero on everything that is not skinned, which the shader
				// reads as nothing because the bucket's flags say there is no skin.
				.pose = node.pose,
			});
		}
		placed++;

		Bucket* bucket = &self.buckets[self.buckets.len() - 1];
		bucket.count++;
		// Correct as running totals only because the sort laid the four cells out in
		// order: each of these counts wherever it finds one, and it is the
		// comparator that makes "how many" the same number as "how many at the
		// front". `static_first` is the size of cell 0 — the visible copies that are
		// not static — which is exactly where cell 1 begins.
		if (draw.visible) bucket.visible++;
		if (draw.visible && !draw.is_static) bucket.static_first++;
		if (draw.is_static) bucket.static_count++;
	}
}

fn ulong bucket_key(uint asset, uint mesh) @inline => ((ulong)asset << 32) | (ulong)mesh;

<*
 How many distinct meshes the buckets cover.

 Not `buckets.len()`: one mesh drawn under two materials is two buckets and one
 mesh.

 A quadratic scan rather than a set, because the buckets are sorted
 material-major and (asset, mesh) pairs are therefore not adjacent, and because
 the count is bucket-sized: a scene with two hundred distinct meshes does forty
 thousand integer compares once per `stats()` call, which is not a number worth a
 hash table and an allocation.
*>
// How many copies the buckets cover. `build_draw_list` in counting mode writes no
// instance array, so this is where the number comes from — and it is the same
// number a writing build would have left in `instances.len()`, because every draw
// increments exactly one bucket's count.
fn uint count_instances(Bucket[] buckets)
{
	uint total = 0;
	foreach (bucket : buckets) total += bucket.count;
	return total;
}

fn uint count_unique_meshes(Bucket[] buckets)

{
	uint unique = 0;
	foreach (i, bucket : buckets)
	{
		bool seen = false;
		for (sz j = 0; j < i; j++)
		{
			if (buckets[j].asset.index == bucket.asset.index && buckets[j].mesh == bucket.mesh)
			{
				seen = true;
				break;
			}
		}
		if (!seen) unique++;
	}
	return unique;
}

<*
 The numbers, computed fresh with culling off.

 Deliberately not a read of the last frame's draw list: "1000 instances is one
 draw call" has to be a fact about the scene, not about where the camera was
 pointing when it was last asked. The side effect is that the draw list is left
 unculled — the next `update` rebuilds it, which it would have done anyway.

 `culled_last_frame` is the one number here that is deliberately *not* computed
 fresh, for that same reason: this rebuild culls nothing, so counting during it
 would report zero however much the camera dropped. It is read off `Scene`'s
 record of the last `update` instead.

 ## Transparency makes this an under-count, on purpose

 The rebuild passes neither the transparent table nor a near plane, so nothing
 here is depth-sorted — which means a frame with transparent materials in it may
 issue *more* draws than this reports. Depth interleaving can only ever split a
 bucket, never merge two, so the number below is a floor rather than an estimate.

 That is the same decision `cull` already forced, one axis further along. A
 depth-sorted count would answer a different number for every camera angle, and
 `draw_calls` would stop being a fact about the scene. `stats()` answers "what
 does this scene cost", not "what did this camera angle cost"; the second
 question is a profiler's and wants the frame.
*>
fn SceneStats Scene.stats(&self, Assets* assets)
{
	self.update_world_matrices();
	// Counting, not writing. Every number below is read off the *buckets*; nothing
	// here has ever looked at an `Instance`, and building 148 bytes per drawable to
	// throw them away is 635 KB on the reference village after every script an
	// agent runs. The buckets still need the sort that produces them, so this is
	// not free; what it saves is the write and the growth of a list a query has no
	// reader for.
	//
	// The list is left empty rather than stale, which is the honest state: the next
	// `update` rebuilds both halves, and it would have done that anyway.
	self.build_draw_list(assets, null, {}, null, {}, null, true);

	SceneStats stats = {
		.draw_calls = (uint)self.buckets.len(),
		.unique_meshes = count_unique_meshes(self.buckets.array_view()),
		// Summed over the buckets rather than read off `self.instances`, which the
		// counting build above deliberately left empty. Same number: every draw that
		// survived lands in exactly one bucket.
		.instances = count_instances(self.buckets.array_view()),
		.assets = assets.resident(),
		.textures = assets.texture_count(),
		.texture_bytes = assets.texture_bytes(),
		.culled_last_frame = self.culled_last_frame,
		.shadow_culled_last_frame = self.shadow_culled_last_frame,
	};

	foreach (&node : self.nodes)
	{
		if (!node.alive) continue;
		stats.nodes++;

		// The same four conditions `rebuild_query_index` files on, in the same
		// order. Kept in step by hand: they are four lines apiece and a shared
		// helper would have to take the `Assets*` and the node and answer a bool,
		// which is what this is.
		if (!node.collides || !node.asset.is_set() || node.mesh == NO_MESH) continue;
		GpuMesh* mesh = assets.mesh(node.asset, node.mesh);
		if (mesh == null || mesh.bvh == null) continue;
		stats.colliders++;
	}

	foreach (bucket : self.buckets)
	{
		GpuMesh* mesh = assets.mesh(bucket.asset, bucket.mesh);
		if (mesh == null) continue;
		stats.triangles += (mesh.index_count / 3) * bucket.count;
		stats.vertices += mesh.vertex_count * bucket.count;

		if (!mesh.has_skin) continue;
		stats.skinned_draws++;
		stats.skinned_instances += bucket.count;
		if (bucket.preskinned) stats.preskinned_instances += bucket.count;
	}

	stats.pose_bytes = assets.pose_bytes();

	return stats;
}

<*
 The world-space bounds of everything drawable in the scene.

 What the camera frames on. Derived from instance bounds rather than from the
 assets' own, because an asset placed a kilometre from the origin is a kilometre
 from the origin.
*>
fn collision::Aabb3 Scene.bounds(&self, Assets* assets)
{
	// Cached, because this is the most expensive query in the project. Every vertex
	// of every drawable node goes through a matrix here — `world_mesh_bounds`
	// explains why it is exact rather than conservative — which is 100k to 370k of
	// them per call on the reference village, twice a frame. `Scene.bounds_box`
	// carries what invalidates it.
	if (self.bounds_current) return self.bounds_box;

	self.update_world_matrices();

	bool found = false;
	collision::Aabb3 total;

	foreach (&node : self.nodes)
	{
		if (!node.alive || !node.asset.is_set() || node.mesh == NO_MESH) continue;
		GpuMesh* mesh = assets.mesh(node.asset, node.mesh);
		if (mesh == null) continue;

		collision::Aabb3 box = world_mesh_bounds(node.world, mesh);
		if (!found)
		{
			total = box;
			found = true;
		}
		else
		{
			total.expand_by_aabb(box);
		}
	}

	// The unit box is cached like any other answer. An empty scene is asked this
	// question by every frame that has shadows on, and re-walking an empty node pool
	// to be told the same thing is the same waste in miniature.
	if (!found) total = { .min = { -1, -1, -1 }, .max = { 1, 1, 1 } };
	self.bounds_box = total;
	self.bounds_current = true;
	return total;
}

<*
 The world-space bounds of one subtree, its root included.

 `Scene.bounds` is this over everything and is what the camera frames on. The
 restricted form is what a *script* needs, and for a different reason: a kit
 piece's origin is wherever its exporter left it, so "put this window on that
 wall" is a question about where the piece's faces are, not about where its
 transform is. Without this the answer has to be carried into the script as a
 hand-copied table of sizes, which goes stale silently.

 Empty rather than unit-sized when nothing under `root` draws. `Scene.bounds`
 answers with a unit box in that case because the camera must point *somewhere*;
 here the caller asked about a specific subtree and "it has no size" is the
 truthful answer, which is why `found` is out-of-band rather than encoded as a
 degenerate box a caller would have to recognise.

 @param found : `Out. False when nothing under root draws — a Group of Groups, or a node whose mesh is not resident. The box is not written then.`
*>
fn collision::Aabb3 Scene.subtree_bounds(&self, Assets* assets, NodeId root, bool* found)
{
	self.update_world_matrices();

	collision::Aabb3 total;
	*found = false;
	self.grow_bounds(assets, root, &total, found);
	return total;
}

<*
 One node's contribution to `subtree_bounds`, then its children's.

 Copies the child list before recursing for `Scene.kill`'s reason: the walk
 reaches the node pool through `self`, and a `Node*` held across it is a pointer
 into a list that may have moved.
*>
fn void Scene.grow_bounds(&self, Assets* assets, NodeId id, collision::Aabb3* total, bool* found)
{
	Node* node = self.node(id);
	if (node == null || !node.alive) return;

	if (assets != null && node.asset.is_set() && node.mesh != NO_MESH)
	{
		GpuMesh* mesh = assets.mesh(node.asset, node.mesh);
		if (mesh != null)
		{
			collision::Aabb3 box = world_mesh_bounds(node.world, mesh);
			if (!*found)
			{
				*total = box;
				*found = true;
			}
			else
			{
				total.expand_by_aabb(box);
			}
		}
	}

	NodeId[] children = node.children.to_tarray();
	foreach (child : children) self.grow_bounds(assets, child, total, found);
}
