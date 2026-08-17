# M2 — the scene graph and instancing

The step-by-step record of what M2 built, what it changed underneath M1, where
it departed from `plan.md`, and what was actually run to believe any of it.
`base_stage.md` is the same document for M0/M1.

**The done condition, from `plan.md` §5: 1000 instances of one asset is one
draw call.** It is met, it is asserted in `three_tests::scene`, and
`--grid 1000` puts it on screen.

	$ three lib/gltf.c3l/test/truck.glb --grid 1000 --headless
	lib/gltf.c3l/test/truck.glb: 4 draw calls, 4000 instances, 4 unique meshes,
	                             1 textures (16384 KiB), 2856000 triangles

Four draws because the truck is four primitives, not because a thousand copies
cost anything.

## The steps

### S1 — `Object3D` (`src/scene/node.c3`)

A parent, a child list, a local TRS, a cached world matrix, a dirty flag.

**Nodes are addressed by `NodeId`, not by pointer.** `Scene` owns every node in
one `List`, so a `Node*` dies the moment another node is created. A `NodeId` is
an index *and a generation*, and the generation is not defensive clutter:
`plan.md` §1 requires a JS handle to revalidate on access and throw rather than
dereference a freed node, and a bare index cannot tell "slot 7" from "slot 7
after something else was put in it". Paying for it now makes M3's binding a
lookup rather than a lifetime redesign.

**`rotation` is XYZ Euler in radians**, in Three.js's default order, because
`m.rotation.y = Math.PI / 2` is what an agent that has memorized Three.js will
write. A quaternion beside it is a second source of truth until there is
something to interpolate.

**Each node carries a normal matrix as well as a world matrix**, and this is the
decision to keep. The upper 3x3 of the world matrix is the shortcut, and it is
only correct for rotation and uniform scale — which the API deliberately does
not restrict itself to. Under `scale.set(1, 2, 1)` the shortcut leaves normals
no longer perpendicular to the surface, so a stretched object is lit as though
it were not: correct geometry, wrong shading, and nothing that reads as an
error. `std::math::matrix` has no `inverse`, so it is `adjoint / determinant`,
transposed.

### S2 — the scene (`src/scene/scene.c3`)

The node pool, the hierarchy, world-matrix propagation, frustum culling, the
instance table, `stats()`.

Three passes, deliberately separate:

	update_world_matrices   parent-relative TRS -> world matrix, dirty-driven
	build_draw_list         traverse, cull, sort by bucket key, write instances
	MeshPass.record         upload, bind, draw

**Bucketing is a sort, not a map.** Each drawable node produces a `(asset, mesh)`
key packed into one `ulong`; the draw list is sorted; a single linear scan turns
runs of equal keys into buckets. No hash, no per-bucket allocation, and the cost
is `n log n` in *instances* rather than anything in unique meshes — a scene of
ten thousand distinct meshes buckets as cheaply as one mesh repeated ten
thousand times. The alternative considered was a linear scan over open buckets,
which is O(instances × unique meshes) and fine right up until it is not.

**Culling is on by default, and `stats()` deliberately ignores it.** An instance
outside the frustum is dropped from the draw list, so reading the last frame's
list would make "1000 instances is one draw call" a statement about where the
camera happened to be pointing. `Scene.stats` rebuilds with culling off.

The frustum is Gribb & Hartmann off the view-projection matrix, with the near
plane taken as row 2 alone — the Vulkan/D3D [0,1] depth convention, not
OpenGL's [-1,1]. The OpenGL form culls nothing that should be culled and is
invisible until something far away disappears.

### S3 — the asset table (`src/scene/asset.c3`)

M1's `Asset` owned its own textures, its own descriptor pool and its own white
stand-in. `plan.md` §2 wants textures deduplicated *across every asset already
loaded*, so all three moved up to a new `Assets`, and `Asset` kept only its
meshes, its bounds and a refcount.

**Descriptor pools are per load, never grown.** One pool sized for exactly the
textures a single `load` added, plus a one-set pool for the white stand-in. A
load that reused every image it referenced creates no pool at all. A pool that
has to grow is a pool that has to be recreated with every set in it rebound.

**Geometry is not deduplicated across assets — only textures and materials
are.** That is what §2 says, and it is worth stating because "linked, not
duplicated" invites the other reading. Two files whose triangles happen to match
are two uploads, because proving they match means comparing them, and a mesh's
equality depends on winding, indexing and vertex order agreeing too.

**Refcounts are maintained; dropping to zero does not unload.** Unloading under
two frames in flight needs the allocator's deferred-delete queue and a caller
that wants it, and nothing does before M6. The count is there so an unused asset
is *knowable*.

### S4 — picking (`src/scene/pick.c3`)

**Built at M2 rather than at M5, and not only because `plan.md` §5 asks for the
BVH here.** A raycast is how the scene-math checks assert without a GPU: "a ray
through this screen point hits instance 7" is exact, needs no window, and
describes the failure that pixel comparison cannot.

One `collision::TriBVH` per unique mesh, built when the asset is uploaded, with
an instance-AABB broad phase in front of it — the same `transform_aabb` frustum
culling uses, which is what §2 means by the broad phase being shared. The cost
is honest: the positions and a triangle index array stay resident on the CPU for
the life of the asset, because `TriBVHNode` points at them rather than copying.

`screen_ray` unprojects the near and far planes of the *same* view-projection
matrix the renderer draws with, rather than deriving a ray from the eye and the
field of view. The two agree only if every convention agrees, and deriving one
from the other is what makes them agree by construction.

### S5 — the push block, and what had to leave it (`src/gpu/pipeline.c3`)

M1's block was 124 bytes of a 128-byte budget. An instance-array pointer is 8
more, and 132 does not fit.

`plan.md` §1's rule is "when something new wants to ride in here, it goes in a
buffer instead", and applying it meant noticing that two of the things already
in the block were never per-draw. The view-projection and the light moved into a
`FrameBlock` written once a frame and reached through one pointer:

	frame        0     8      -> FrameBlock, one per frame in flight
	instances    8     8      -> Instance[], already offset to this bucket
	positions   16     8
	normals     24     8
	uvs         32     8
	base_color  40    16
	flags       56     4      = 60 used, 64 with tail padding

The budget stopped being tight rather than being widened. `MeshPush::size`,
`FrameBlock::size` and `Instance::size` are `$assert`-ed to exact numbers rather
than to a bound, because all three are a wire format shared with
`shaders/mesh.slang` and a silent change to either side is a misread buffer, not
an error.

**`Instance` is 128 bytes** — two `float4x4`, model and normal. Under scalar
layout a `float4x4` is 4-byte aligned, so an array of them is tightly packed and
`SV_InstanceID` indexes it with no padding rules to get wrong. C3's `Matrix4f`
is 64 bytes at 4-byte alignment, checked rather than assumed.

### S6 — the instance array (`src/render/pass.c3`, `src/gpu/buffer.c3`)

Host-visible and coherent rather than device-local with a staging copy, which is
the opposite of `upload_stream` and for the opposite reason: this content
changes every frame, so a staged upload would be a copy and a barrier per frame
to save a read that happens once per vertex.

**One buffer per frame slot.** `gpu/frame.c3` has stated the rule since M0 and
this is the first thing in the project it applies to. Writing *and growing* a
slot's buffer is safe only after that slot's fence has been waited on, which is
what `Renderer.frame` and `Renderer.capture` both do before recording. Freeing
the other slot's buffer here would be a use-after-free the validation layers
would not always catch — which is exactly how crig's pose palette tore.

The bucket's slice is handed to the shader as a *pointer already offset* rather
than as a base index, so `SV_InstanceID` starts at zero in every draw and the
firstInstance-versus-InstanceIndex distinction never has to be resolved.

### S7 — the shader (`shaders/mesh.slang`)

`SV_InstanceID` indexes the instance array; the model matrix places the vertex;
the normal matrix rotates the normal; the frame block supplies the
view-projection and the light.

**There is no non-instanced path.** A lone mesh is a bucket of one, drawn by the
same call with an instance count of one, reading its transform out of the same
array. That is what makes "a thousand walls is one draw call" a property of the
API rather than something an optimisation has to notice.

## What was wrong before M2 and is fixed now

- **`GpuMesh.name` was freed memory.** It held `gltf::Mesh.name`, which
  `GltfStream.close` frees at the end of the load. Harmless for the whole of M1
  because nothing read a name; M2 is where looking a mesh up by name starts to
  matter. Names are now owned copies, freed with the mesh.
- **`project.json`'s shader target was missing `-force-glsl-scalar-layout`.**
  The header of `mesh.slang` documents the flag and `c3c build shaders` was not
  passing it, so the manifest and the documented command produced *different*
  SPIR-V — confirmed by comparing the two outputs, not by reading. Nothing had
  noticed because the offsets that differ are ones M1 never used. Fixed, with
  the reason in the manifest.

## Where this departed from `plan.md`

- **`scene/material.c3` was not written.** At M2 a material is a base colour
  factor and a texture index, both on `GpuMesh`, both resolving to the one
  pipeline; a struct with exactly those two fields would be a second name for
  something that already has one. It belongs with `ShaderMaterial` at M5. The
  consequence to know: the bucket key is `(asset, mesh)` rather than
  `(mesh, material)`, and those are the same key only while this holds.
- **`scene/pick.c3` was written early** — see S4.

## Verification

	c3c build                                            clean
	c3c test --trust=full --test-noleak                  28 passed, 0 failed
	c3c test --trust=full                                28 passed, leak-clean

`three_tests::scene` is seventeen of those. Six of the seventeen — every check on
the hierarchy, the dirty flag, handle staleness and the normal matrix — build a
`Scene` and nothing else, so they need no Vulkan device at all and run in
microseconds. The rest are headless: a device, no window, no surface.

**Every regression test here was checked by re-introducing the bug it claims to
catch** (`plan.md` §7: an unexercised regression test is an assumption). Each
was injected, the named test observed to fail, and the source restored and
re-verified byte-identical:

| bug injected | test that caught it |
|---|---|
| normal matrix returns the model matrix | `the_normal_matrix_undoes_a_non_uniform_scale` |
| dirty flag stops after one level | `dirt_propagates_all_the_way_down` |
| shader reads `instances[0]` for every instance | `instances_land_where_their_transforms_say`, `the_instance_buffer_grows_and_stays_stable` |
| hit distance returned in local units | `picking_respects_an_instance_scale` |
| freed slot does not bump its generation | `a_removed_node_leaves_a_stale_handle` |
| buckets built without the sort | `interleaved_meshes_still_bucket` |
| texture content hash ignored | `two_assets_sharing_an_image_upload_it_once`, `identical_textures_upload_once` |
| shader ignores the per-instance normal matrix | `the_shader_rotates_normals_per_instance` |

On top of that, run by hand:

| what | result |
|---|---|
| `--grid 1000` on a four-primitive `.glb`, headless | 4 draw calls, 4000 instances |
| `--grid 100 --screenshot`, inspected | a 10x10 grid of trucks, correctly lit and spaced |
| `--grid 400 --stress-resize --validate` | clean through six extents plus minimise/restore |
| the same on `--system-driver` | clean |

The resize stress is the M0 check with 1600 instances behind it, and it is
where a per-slot instance buffer that was actually shared would show up: the
swapchain rebuild changes how frames pair with slots.
