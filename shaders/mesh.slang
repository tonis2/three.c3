// three.c3 mesh pass.
//
// **Compiled at runtime, from this file, every time the app starts.** There is
// no build step, no slangc invocation anywhere in the project, and no .spv on
// disk — src/shader/compile.c3 reads this text and hands Slang the string.
// Editing it and re-running shows the change; nothing is rebuilt, not even the
// shader.
//
// M1 read a slangc-produced mesh.spv here and M4 replaced it. The two are not
// merely equivalent: the runtime compile emits the **byte-identical module**
// that `slangc -target spirv -emit-spirv-directly -fvk-use-entrypoint-name
// -force-glsl-scalar-layout` did. Getting there needed one flag that was never
// in that command line — `-matrix-layout-column-major`, which slangc defaults
// to and the compile-request API does not. See SLANG_ARGUMENTS.
//
// **There is no vertex input state anywhere in this project.** Geometry arrives
// as buffer device addresses — in the draw record below, reached through the one
// pointer the push block carries — and is indexed by SV_VertexID; an index
// buffer is still bound the ordinary way with vkCmdBindIndexBuffer,
// which is independent of vertex bindings, so SV_VertexID arrives already
// resolved through it. Three.js's entire BufferGeometry attribute-binding layer
// never gets written.
//
// **Instancing is the only way anything is drawn**, including the single copy
// case. There is no non-instanced path to fall back to and no per-draw model
// matrix: SV_InstanceID indexes an array of transforms the scene wrote this
// frame, and a bucket of one instance is a bucket of one. That is what makes
// "a thousand walls is one draw call" a property of the API rather than an
// optimisation something has to notice.
//
// **Scalar layout, and the device is checked for it.** Apple M5 reports
// scalarBlockLayout under KosmicKrisp, the driver this project renders through
// (see gpu/device.c3), so the streams below are read as tightly packed float3
// and float2 — exactly the layout glTF hands over, with no CPU repack. Under
// standard std430 a float3 would take a 16-byte stride and every read here
// would be off by a third. gpu/pipeline.c3 refuses a device that lacks the
// feature rather than drawing garbage.

// One instance: where a copy of the mesh is, and how its normals rotate.
//
// **`normal` is not `model`.** It is the inverse transpose of the model
// matrix's linear part, which is what a normal has to be transformed by. Using
// `model` is only correct for rotation and uniform scale, and the scene API
// deliberately allows a non-uniform one — under which the shortcut leaves
// normals no longer perpendicular to the surface and the object is lit as
// though it were not stretched. Nothing about that reads as an error.
// **`color` and `variant` are the only things two copies of a mesh may disagree
// about.** Everything else that decides how a draw looks — the pipeline, the
// uniforms, the texture — is pushed once for the whole vkCmdDrawIndexed, so a
// disagreement about any of it is a second bucket and a second draw. These two
// are read per instance, so a thousand differently coloured copies are still one
// call. `scene/scene.c3` writes them; `variant` means nothing to this shader and
// selects a row of the material's table in `material.slang`.
struct Instance
{
    float4x4 model;
    float4x4 normal;
    float4 color;
    uint variant;
    // Where this copy's joint matrices start, in matrices, and which buffer they
    // are in — the top bit is POSE_LIVE and the rest is the offset.
    //
    // **The third thing two copies of a mesh may disagree about, and the one that
    // makes a crowd affordable.** A hundred characters mid-stride at a hundred
    // different phases differ by this one uint: they key different frames out of
    // the same baked table and stay a single vkCmdDrawIndexed. Zero on a mesh with
    // no skin, and pointing at the skin's rest pose on one that has never played.
    uint pose;

    // The frame this copy is crossfading *out of*, and how much of it is still
    // showing — 1 when a fade begins, counting down to 0 as the new pose arrives.
    //
    // **Zero is "not fading", and it is zero because that is the quiet default.**
    // A copy that has never crossfaded, a mesh with no skin and a freshly recycled
    // slot all carry zero here, and zero reads as `pose` alone. See `skin_matrix`
    // for what mixing two baked frames costs and why it is taken.
    uint pose_from;
    float blend;

    // Which slice of `FrameBlock.morph_weights` this copy reads, plus one. Zero is
    // "this copy does not morph", and is the quiet default every copy of every
    // unmorphed mesh carries. Per instance for `pose`'s reason: two faces built
    // from one head mesh wear different expressions and stay one draw call.
    uint morph;

    // Where this copy's lightmap tile is: xy the atlas uv of its corner, zw its
    // size. **zw zero is "this copy has no tile"**, which is every copy of every
    // scene until `three.lights.bake()` has run and is what makes the lightmap a
    // per-copy property rather than a bucket one — two copies of one mesh light
    // differently and still draw in one call. `render/lightmap.c3` writes it.
    float4 lightmap;
};

// One registry light. The frame carries a pointer to the variable-length table.
struct Light
{
    float4 direction;
    float4 color;
    float4 area_right;
    float4 area_up;
    uint4 meta;
};

// What every draw in the frame shares. Written once per frame rather than
// pushed per draw, which is what freed the room in the push block for
// instancing — see gpu/pipeline.c3.
struct ShadowGpuView
{
    float4x4 view_projection;
    float4 atlas;
    float4 params;
    float4 dynamic_rect;
    // Frame constants for the receiver-plane gradient: row i of the cofactor of
    // `view_projection`'s upper-left 3x3 in xyz, and component i of that 3x3's
    // inverse-transpose times the projection's w row in w.
    float4 plane_x;
    float4 plane_y;
    float4 plane_z;
};

struct FrameBlock
{
    float4x4 view_projection;
    // The two numbers the whole frame's lighting shares, as opposed to the
    // per-light ones in `lights` below.
    //
    //   x  the ambient floor: how much of its own colour a surface keeps where no
    //      light reaches it. `three.light.ambient`.
    //   y  how many entries in the light registry are live.
    //   z  game clock seconds — `three.clock.time`, the same number `p.time` is.
    //   w unused.
    float4 lighting;
    // This frame's live joint matrices — the characters whose pose is computed
    // from their bone nodes rather than read out of a baked table.
    //
    // **Here rather than in the draw record**, because it is one buffer for the
    // whole frame while a record is per bucket: a live character and a baked one
    // sharing a mesh and a material are one bucket, and giving the record a single
    // palette pointer would have forced them apart into two draws. Null in a frame
    // where nothing is live, which is every frame of a scene with no skeletons.
    float4x4* live_poses;
    // Where the light is looking from, as one matrix: the orthographic
    // view-projection `render/shadow.c3` fitted around the scene this frame.
    // `shaders/shadow.slang` renders the depth map with it and `shadow_factor`
    // below reads the map back with the same matrix, which is what makes the two
    // agree — one fit, written once per frame, used by both ends.
    //
    // Identity, and unread, in a frame with no shadow pass: `shadow.w` is what
    // says which, and it is zero then.
    float4x4 light_view_projection;
    // The four numbers the lookup needs, and `shadow.w` is the switch.
    //
    //   x  one shadow texel in uv, so the PCF taps are a texel apart whatever
    //      size the map was created at
    //   y  the depth bias, in the light's ndc depth units — what a script sets
    //      as `three.light.shadow.bias`
    //   z  how far along the surface normal a sample is nudged before it is
    //      projected, in world units. Derived from the fitted extent rather than
    //      set by anybody, so it scales with the scene — see `render/shadow.c3`
    //   w  how dark a shadow is, 0 to 1, and **0 is also how "no shadow pass ran
    //      this frame" is spelled**. One number for both because the shader's
    //      answer is the same either way: an intensity of zero and no map are
    //      both "nothing is occluded", and a second flag would be a second thing
    //      to keep in step with the first.
    float4 shadow;
    // **`three.debug.view`, and nothing else reads it.** x is the mode, as
    // `render/pass.c3` writes it: 0 draws the scene, 1 draws the shadow factor,
    // 2 draws what the shadow lookup would read. yzw are unused and are the room
    // a view that needs a parameter would take.
    //
    // A whole float4 for one number because that is what the block is already
    // aligned to — a scalar here would cost the same sixteen bytes and would
    // have to be repacked the first time a second view wanted an argument.
    float4 debug;
    // Where the camera is, in world space. w unused.
    //
    // **Only the specular term reads it.** A highlight is the one thing here that
    // depends on which way a surface is being looked at, and the view-projection
    // above is not invertible cheaply enough to ask it per fragment.
    float4 camera;
    // The sky, as the surfaces that reflect it need it.
    //
    //   x  intensity, and **zero means there is no environment**. The one number
    //      the reflection branches on, so a scene without a sky costs a compare.
    //   y  rotation about world Y in radians — the same angle `sky.slang` turns
    //      the background by, so a metal reflects the sky that is on screen.
    //   z  the environment image's highest mip level, which is what turns
    //      `roughness` into a blur.
    //   w  unused.
    float4 environment;
    // The frame's lights, `lighting.y` of them, light zero first.
    //
    // **At the end of the block on purpose.** Everything above kept the offset it
    // had when there was one light, and `shaders/shadow.slang` reads
    // `light_view_projection` at 88 by that offset.
    Light* lights;
    // This frame's morph weights: one float per target per morphing copy, packed
    // end to end. An instance names its slice with `Instance.morph`, and the
    // bucket says how many of them to read with `Draw.morph_targets`.
    //
    // **Here rather than in the draw record** for `live_poses`' reason: the record
    // is per bucket, and a weight pointer there would split a morphing copy of a
    // mesh away from the still copies it shares a draw call with. Null in a frame
    // where nothing morphs, which is every frame of most projects.
    //
    // **After `lights` on purpose**, which is the rule the comment above states:
    // every field kept the offset it had, so nothing that reads this block by
    // offset had to change.
    float* morph_weights;
    // The world itself as a light: `three.light.world`, xyz linear rgb, w unused.
    //
    // **Added under the shading rather than lerped into it**, which is the whole
    // difference between this and `lighting.x`. It is Blender's world colour — a
    // uniform light arriving from every direction at once — so it raises a
    // shadowed face without taking anything away from a lit one, where the
    // ambient floor fades the direct term against itself. Black in every scene
    // that does not ask for it.
    //
    // **After `lights` and after `morph_weights`**, which is the rule the two
    // comments above state: every field kept the offset it had.
    float4 world;
    float4 point_shadow;
    float4x4 inverse_view_projection;
    float4 ambient_occlusion;
    ShadowGpuView* shadow_views;
    uint* cluster_counts;
    uint* cluster_indices;
    uint4 cluster_grid;
    float4 cluster_screen;
};

// Everything about one bucket that is not the geometry itself: where to read the
// streams, what colour the surface is and how its texture is laid on.
//
// **This is a record in a buffer, not a push constant, and that is the whole of
// why anything new can be added to it.** Until the draw buffer existed these
// seven fields were pushed per draw, which put them in permanent competition with
// a material's uniforms over the 128 bytes every device must offer — 76 here left
// 52 there, and a ninth field would have taken eight more. Now the push block
// carries the *address* of this and the competition is over: one more stream
// costs 8 bytes of a buffer sized by the frame's bucket count.
//
// `render/pass.c3` writes one of these per bucket into a host-visible buffer and
// pushes the address of this bucket's own, so `push.draw[0]` is always the right
// record and no index arithmetic reaches the shader. `gpu/pipeline.c3`'s
// `DrawRecord` is the same struct on the C3 side. Slang reflects a push block and
// not the type behind a pointer, so the two are held together by a test rather
// than by the pipeline build: `the_draw_record_matches_the_shader` compiles this
// declaration *as* a push block to get its offsets, and
// `every_shader_declares_the_same_contract` checks this text against the copies
// in `material.slang` and `shadow.slang`.
// One vertex as the compute pass leaves it: posed, in the character's own space,
// one copy per instance.
//
// Position and normal interleaved, unlike the geometry streams above, because
// these two are written by one thread and read by one thread — the pair is the
// unit of work, and splitting it would make two scattered writes per vertex out
// of one. `shaders/skin.slang` writes it and `gpu/pipeline.c3` declares the same
// 24 bytes.
struct SkinnedVertex
{
    float3 position;
    float3 normal;
};

// One vertex's displacement for one morph target. Byte for byte what
// `gpu/pipeline.c3` declares, and the same 24 bytes as `SkinnedVertex`.
//
// **Displacements, not positions.** glTF stores morph targets as deltas from the
// base mesh, and that is the only form that composes: a face wearing a smile and
// a blink at once is the sum of two displacements, where the sum of two absolute
// positions is not a face.
struct MorphDelta
{
    float3 position;
    float3 normal;
};

struct Draw
{
    // Three separate streams rather than one interleaved Vertex: that is how
    // glTF stores them, so uploading is a memcpy per accessor and the vertex
    // shader reads what the file contained.
    float3* positions;
    float3* normals;
    float2* uvs;
    // Separate non-tiling coordinates for the static light cache. Material
    // sampling always continues through `uvs`.
    float2* lightmap_uvs;
    // glTF's COLOR_0, if the file carried one. Multiplied into albedo below when
    // `FLAG_HAS_COLORS` is set and `FLAG_COLORS_ARE_MASK` is not — the
    // specification defines it as a **linear** factor on the base colour, so it is
    // used as it arrives and not decoded, on the same reasoning that leaves
    // `base_color` alone, and the second flag is the file saying it painted a mask
    // here rather than a tint. `material.slang` also hands it to a body as
    // `s.vertex_color`, where a body may do something else with it entirely.
    float4* colors;
    // glTF's JOINTS_0 and WEIGHTS_0: which four joints move this vertex and how
    // strongly. Widened to uint4 on upload from whatever width the file stored
    // them at, and the weights renormalised — glTF blends without normalising, so
    // a vertex whose weights sum to 0.8 sits at 80% of the way to the origin and
    // the mesh visibly deflates.
    uint4* joints;
    float4* weights;
    // This asset's baked joint matrices: every clip of every skin, sampled at a
    // fixed rate and folded through the inverse bind pose once at load. Immutable
    // for the life of the asset, which is the whole reason a crowd is free — there
    // is nothing to upload per frame and nothing that can tear.
    //
    // Null on a bucket with no skin, and unread on one the compute pass already
    // posed. A *live* character's matrices are not in here; see
    // `FrameBlock.live_poses` and `skin_matrix`.
    float4x4* palette;
    // Where the compute pass wrote this bucket's posed vertices, one copy of the
    // mesh per instance, or null on every bucket it did not run for.
    //
    // **A pointer of its own rather than swapping `positions` for it**, which was
    // the first shape and was wrong: `positions` is also what a material body
    // reads as `Vertex.local`, and a body that sizes a ripple by the mesh's own
    // length wants the *bind* pose there. Overloaded, the ripple would slide
    // across the surface as the character moved — an effect that looks like a
    // material bug and is a record that changed meaning underneath it.
    SkinnedVertex* posed;
    // This mesh's morph targets: `morph_targets` blocks of `vertex_count`
    // displacements each, target-major, so one target's block is contiguous and
    // the loop below walks it with one stride. Null on every mesh without them,
    // which is nearly all of them.
    MorphDelta* morph;
    // rgb: albedo factor. a: the alpha this returns — the mesh's own alpha
    // times `material.opacity`, folded together on the C3 side so the shader
    // sees one number. Ignored by an opaque pipeline, which writes no alpha at
    // all; `BlendMode` says which pipelines read it.
    float4 base_color;
    uint flags;
    // The mesh's vertex count, and the stride two readers need. Under
    // FLAG_PRESKINNED the compute pass wrote one posed copy of the mesh per
    // instance into a single buffer, so a vertex is at `iid * skin_stride + vid`.
    // Under `morph_targets` the displacement table holds one block per target, so
    // target t's delta for this vertex is at `t * skin_stride + vid`. Zero when
    // neither is running, where the streams hold one shared copy and SV_VertexID
    // indexes it directly.
    uint skin_stride;
    // How many of `morph`'s blocks to apply, and how many weights this bucket's
    // instances read. **Zero is the whole test** — a mesh with no targets, a soft
    // bucket, or a frame with no weight buffer all arrive here as zero and the
    // loop does not run.
    uint morph_targets;
    // xy: how many times the texture repeats across the surface. zw: where it
    // starts. `{1, 1, 0, 0}` is the identity and is what a material with no
    // transform is given — `scene/material.c3` says why a zero repeat means
    // "unset" rather than meaning a texture collapsed onto one texel.
    //
    // **Here rather than in a material's uniforms**, and when it was pushed it
    // cost 16 of the 68 bytes those had. The alternative was per-material
    // uniforms, which only a ShaderMaterial has — and the surface that needed
    // this most is a ground plane wearing a MeshLambertMaterial, which compiles
    // nothing and has no uniform block at all.
    float4 uv_transform;
    // What the light does when it hits, as opposed to what colour it finds
    // there: x roughness, y metalness, z reflectance, w unused.
    //
    // `{1, 0, 0, 0}` is a matte dielectric with no highlight at all, which is
    // what every material is until a script says otherwise, and is exactly the
    // surface this renderer had before there was a specular term. See
    // `scene/material.c3`, which has why 0 rather than glTF's own defaults.
    float4 surface;
    // How many rows of `uv_variants` this material declared, and **zero is the
    // whole test** — a material nobody asked for one, and every material written
    // before there were any, arrives here as zero and neither template looks at
    // the table.
    uint uv_variant_count;
    // One uv transform per copy, picked by `Instance.variant` and applied to the
    // mesh's own uv before `uv_transform` scales it — `variant_uv` in
    // `surface.slang` is the whole of what a row means. Eight rows because a
    // wall wants more than four and a record that is mostly table stops being a
    // record; a script that wants a thousand variations wants a different
    // feature.
    float4 uv_variants[8];
    // What this surface gives off regardless of any light — `material.emissive`
    // times `material.emissiveIntensity`, linear rgb, and w unused.
    //
    // **Added after the shading rather than folded into the albedo**, which is the
    // whole of what an emissive is: a lamp's glass is bright where nothing is
    // lighting it, and a black surface can glow. Zero on every material nobody set
    // one on, which is the value the record already holds.
    float4 emissive;
    // One slot of the device-wide texture array per binding — see `Map` and
    // `map_at` in `surface.slang`. Indexed by what used to be the descriptor
    // binding, so a material's maps kept their numbers when they left the
    // per-draw descriptor set. Every slot nothing filled holds the array's
    // reserved 1x1 white.
    uint texture_index[24];
};

struct PushData
{
    FrameBlock* frame;
    // Already offset to this bucket's first instance, so SV_InstanceID starts at
    // zero in every draw. Doing the arithmetic on the CPU is what keeps the
    // firstInstance-versus-InstanceIndex distinction from ever mattering here.
    Instance* instances;
    // This bucket's record, offset on the CPU for the same reason `instances`
    // is: the shader reads element zero of its own slice and never learns that
    // the frame's other draws are in the same buffer.
    Draw* draw;
};
[vk_push_constant] const PushData push;

// A stream that is absent is absent, not zero-filled: a null pointer costs no
// flag bit, but reading one is a device-lost rather than a fallback, so the
// flags say which streams are really there and the reads are guarded by them.
static const uint FLAG_HAS_NORMALS = 1u;
static const uint FLAG_HAS_UVS     = 2u;
static const uint FLAG_HAS_COLORS  = 4u;
// The bucket carries joints and weights and its vertices are posed here.
static const uint FLAG_HAS_SKIN    = 8u;
// The bucket's vertices were posed by the compute pass before the render pass
// began, so `positions` and `normals` are already in the character's posed local
// space and this shader must not blend them a second time. The two skin flags are
// mutually exclusive by construction — `render/pass.c3` sets one or the other.
static const uint FLAG_PRESKINNED  = 16u;

// The three maps the built-in material carries past its base colour, one bit
// each, set by `build_draw_records` from the material's own texture slots.
//
// **A bit rather than a comparison against white**, because white is not the
// identity for two of the three. Every declared binding is written every draw —
// leaving one unwritten is undefined behaviour, see `render/bind.c3` — and what
// goes in an empty one is the same 1x1 opaque white image `base_color_map` falls
// back to. Through `mapped_normal_frame` that texel is a direction of (1,1,1),
// which leans every fragment of every untextured surface the same way; through
// the metallic-roughness decode it is a fully metallic mirror. So the flag says
// whether to sample at all, and it costs three bits of a field that had
// twenty-seven free.
static const uint FLAG_HAS_NORMAL_MAP              = 32u;
static const uint FLAG_HAS_METALNESS_ROUGHNESS_MAP = 64u;
static const uint FLAG_HAS_OCCLUSION_MAP           = 128u;

// `material.stochastic` — sample this material's maps through `stochastic_sample`
// instead of straight, so a tiled surface stops having a period. `plan.md` §27.
//
// **One bit for all four maps and not one per map**, because they describe one
// surface: albedo jittered one way and the normal another is a surface whose
// colour and whose relief disagree about where they are, and that reads as a
// broken material rather than as a broken option.
static const uint FLAG_STOCHASTIC                  = 256u;
// Whether `emissive_map` is this material's own. Zero on every material that
// glows a flat colour and on every one that does not glow at all, which is the
// same test the three map flags above make.
static const uint FLAG_HAS_EMISSIVE_MAP            = 512u;

// This mesh's COLOR_0 is a mask an artist painted rather than a colour, so the
// albedo must not multiply by it.
//
// **glTF's rule for COLOR_0 is a tint and this is the exception to it**, set from
// the file rather than guessed: `scene/asset.c3` raises it when the primitive's
// material carries `CUSTOM_materials_layers`, whose layers take their weight from
// a channel of this attribute. Three unrelated weights multiplied into a texture
// is a rainbow, which is what the surface draws until a stack is put on it — and
// a stack with no layers left in it takes the same door, because the attribute
// was painted for one either way.
//
// `material.slang` has no need of the bit: a body reads the attribute as a weight
// through `Surface.vertex_mask` and as a colour through `Surface.vertex_color`,
// and decides for itself which it meant.
static const uint FLAG_COLORS_ARE_MASK             = 1024u;

// `Instance.pose` is an offset in matrices with a selector in its top bit: set
// means this frame's live palette, clear means the asset's baked table.
static const uint POSE_LIVE = 0x80000000u;
static const uint POSE_MASK = 0x7fffffffu;

// The material's own maps are **not** bindings any more. Each is a slot of the
// device-wide texture array, named here by the number it used to be bound at and
// reached through `map_at` — see `Map` in `surface.slang`. A slot nothing filled
// holds the array's 1x1 opaque white, so there is still one pipeline and one
// descriptor layout rather than a permutation per material.
static const uint SLOT_BASE_COLOR = 0u;

// **Binding 1 is the shadow map, in every shader that shades a surface.** It is
// reserved the way `base_color_map` is — declared by the template rather than by
// anything a script writes — which, with the environment map below it, is why
// `MATERIAL_BINDING_FIRST` is 4 and an agent's first sampler is numbered from
// there. `shader/assemble.c3` has the
// argument for why reserving a binding is a constant and never a shared bump.
//
// **Always bound and always valid, exactly like binding 0.** With no shadow pass
// this carries the same 1x1 opaque white image an untextured material samples,
// and white is the right answer by construction: a depth of 1.0 is the far plane,
// nothing is in front of anything, and the comparison below comes out lit. So
// there is one pipeline and one descriptor layout whether shadows are on or off,
// and turning them on is a different image in the same slot rather than a
// recompile.
[vk::binding(17, 0)] Sampler2D shadow_atlas;
// The same image through a depth-compare sampler: one tap is four texel
// comparisons filtered in hardware. `shadow_atlas` above stays for the debug
// view, which wants the depth itself.
[vk::binding(18, 0)] Sampler2DShadow shadow_atlas_compare;
[vk::binding(21, 0)] Sampler2DShadow shadow_atlas_static_compare;
// The linearly-transformed-cosine table for area lights: one 64x128 image
// holding the fitted inverse transform and the GGX norm/Fresnel split. See
// `lighting.slang`; `FrameBlock.lighting.w` says whether it is bound. Absent
// where the numeric integration is the answer, so a material at the sampler
// limit still fits a portable device.
#if !defined(THREE_AREA_REFERENCE) && !defined(THREE_BAKE)
[vk::binding(19, 0)] Sampler2D ltc_lut;
#endif
// The baked static light cache. One image for the whole scene; a copy's tile is
// `Instance.lightmap` and `render/lightmap.c3` fills it.
[vk::binding(20, 0)] Sampler2D lightmap_atlas;
#ifndef THREE_NO_AO
[vk::binding(4, 0)] Sampler2D ambient_occlusion_depth;
#endif

float crevice_occlusion(float3 position, float3 normal)
{
#ifdef THREE_NO_AO
    return 1.0;
#else
    float4 settings = push.frame[0].ambient_occlusion;
    if (settings.x <= 0.0) return 1.0;
    float4 clip = mul(push.frame[0].view_projection, float4(position, 1.0));
    float2 uv = float2(0.5 + 0.5 * clip.x / clip.w, 0.5 - 0.5 * clip.y / clip.w);
    if (clip.w <= 0.0) return 1.0;
    float3 right = normalize(mul(push.frame[0].inverse_view_projection, float4(1,0,0,0)).xyz);
    float3 up = normalize(mul(push.frame[0].inverse_view_projection, float4(0,1,0,0)).xyz);
    float4 clip_right = mul(push.frame[0].view_projection, float4(position + right * settings.y, 1.0));
    float4 clip_up = mul(push.frame[0].view_projection, float4(position + up * settings.y, 1.0));
    float2 axis_x = float2(0.5 * clip_right.x / clip_right.w + 0.5 - uv.x, 0.5 - 0.5 * clip_right.y / clip_right.w - uv.y);
    float2 axis_y = float2(0.5 * clip_up.x / clip_up.w + 0.5 - uv.x, 0.5 - 0.5 * clip_up.y / clip_up.w - uv.y);
    const float2 taps[12] = {
        float2(.25,0), float2(0,.25), float2(-.25,0), float2(0,-.25),
        float2(.424,.424), float2(-.424,.424), float2(-.424,-.424), float2(.424,-.424),
        float2(1,0), float2(0,1), float2(-1,0), float2(0,-1)
    };
    float blocked = 0.0;
    for (uint i = 0; i < 12; i++) {
        float2 at = uv + axis_x * taps[i].x + axis_y * taps[i].y;
        if (any(at <= 0.0) || any(at >= 1.0)) continue;
        float depth = ambient_occlusion_depth.SampleLevel(at, 0.0).r;
        if (depth >= 0.999999) continue;
        float4 world = mul(push.frame[0].inverse_view_projection, float4(at.x * 2.0 - 1.0, 1.0 - at.y * 2.0, depth, 1.0));
        if (abs(world.w) <= 1e-6) continue;
        float3 delta = world.xyz / world.w - position;
        float distance = length(delta);
        if (distance > settings.y || distance <= 1e-5) continue;
        blocked += step(settings.z, dot(normalize(normal), delta)) * (1.0 - distance / settings.y);
    }
    return 1.0 - settings.x * blocked / 12.0;
#endif
}

// **Binding 2 is the environment map, in every shader that shades a surface.**
// The third and last binding a template reserves, which is why
// `MATERIAL_BINDING_FIRST` is 4 and an agent's first sampler is numbered from
// there.
//
// Always bound and always valid, exactly like the two above: with no sky it
// carries the same 1x1 opaque white image, and what stops that white from
// putting a mirror finish on every metal in every scene is
// `push.frame[0].environment.x`, which is zero then. One number rather than a
// second pipeline, for binding 1's reason.
//
// Equirectangular — one 2D image, latitude down and longitude across — so this
// is an ordinary `Sampler2D` and there is no cube view anywhere in the project.
// `shaders/sky.slang`'s header has the argument.
[vk::binding(2, 0)] Sampler2D environment_map;

// **Bindings 3, 4 and 5 are the built-in material's other three maps**, and they
// are this shader's alone: `material.slang` reserves three bindings and numbers
// an agent's first sampler at `MATERIAL_BINDING_FIRST`, which is also 4. Two
// templates, two meanings for one number, and nothing is confused by it because
// a binding is only ever resolved against the pipeline that declared it — see
// `render/bind.c3`, where the write site walks the *reflected* layout.
//
// They are reached by index rather than by name, exactly as the shadow map and
// the environment map above are, and for the same reason: only the pass knows
// what each image is. `MeshPass.set_material_slot` is the door, and no script
// ever spells `normal_map`.
//
// All three are always bound and always valid, and all three are white when the
// material named nothing — which is why the flags above exist rather than a
// comparison against the texel.
//
// **`normal_map` and `metalness_roughness_map` are data and not pictures.** Both
// have to be uploaded `LinearSRGBColorSpace` or the sRGB decode in the sampler
// bends every value: a normal that means "no tilt" arrives leaning, and a
// roughness of 0.5 arrives at 0.21. `js/prelude/texture.js` is where a script
// says so, and the glTF importer already does.
static const uint SLOT_NORMAL = 5u;
// glTF's packing, and the reason this is one image rather than two: **green is
// roughness and blue is metalness**, which is what `pbrMetallicRoughness` in
// glTF 2.0 defines and what every exporter writes. Red is unused here and is
// where the specification allows an occlusion map to be packed alongside; this
// renderer keeps occlusion in its own binding so the two can come from different
// files.
static const uint SLOT_METALNESS_ROUGHNESS = 6u;
// Ambient occlusion, red channel, glTF's `occlusionTexture`. What it multiplies
// is in `fragmentMain` and is the whole of why it is worth having a term rather
// than folding it into albedo.
static const uint SLOT_OCCLUSION = 7u;
// glTF's `emissiveTexture`, multiplied by `Draw.emissive` and added after the
// shading. **A picture and not data** — it is the colour of the light this
// surface gives off — so it uploads sRGB, unlike the three above it.
static const uint SLOT_EMISSIVE = 8u;

// The four influences of one vertex against one palette, summed into the matrix
// that poses it.
//
// Split out of `skin_matrix` so a crossfade can spend it twice: the two frames a
// fade sits between are two offsets into one buffer, and everything else about
// the vertex — its joints, its weights — is the same for both.
float4x4 blend_joints(float4x4* palette, uint base, uint4 joints, float4 weights)
{
    // Summed rather than interpolated: linear blend skinning is a weighted sum of
    // the joint matrices, and the weights are normalised on upload so the sum is
    // affine. This is the one place the four influences per vertex are spent.
    return weights.x * palette[base + joints.x]
         + weights.y * palette[base + joints.y]
         + weights.z * palette[base + joints.z]
         + weights.w * palette[base + joints.w];
}

// The four influences of one vertex, blended into the matrix that poses it.
//
// **Which buffer the palette lives in is a property of the instance, not of the
// bucket.** A baked copy reads the asset's immutable table through `draw.palette`;
// a live one — a character whose bones a script can write, for IK or a look-at —
// reads this frame's palette through the frame block. The selector is one bit of
// `Instance.pose` and it is uniform across an instance, so this is a scalar
// select and not divergence, and the two kinds of character stay in one bucket.
//
// An `if` rather than a ternary, for the reason `vertexMain` gives below: a
// ternary invites the compiler to evaluate both sides, and one of these two
// pointers is null on any given draw.
// **The crossfade below is a lie, and this is the name of it: it mixes joint
// *matrices*, not the transforms that produced them.** A weighted sum of two
// rigid transforms is not a rigid transform — the rotation part contracts toward
// the chord between the two orientations, so a joint halfway through a fade is
// fractionally shorter than the bone it is meant to be, and two poses a half-turn
// apart pass through zero and turn the limb inside out on the way.
//
// It is taken anyway, on the baked path only, because the alternative is not a
// better crossfade — it is no crossfade at all. A baked pose *is* a table lookup;
// recovering the TRS triples behind two frames in order to slerp them means
// decomposing a hundred and twenty matrices per character per frame, which is the
// live palette with extra steps and a worse constant. A fade is short and runs
// between two poses of one rig, where the contraction is a fraction of a percent
// of a bone length for a fraction of a second.
//
// **A character that cannot afford the lie asks for the live path.** There
// `AnimationPlayer` blends positions with a lerp and rotations with a slerp, on
// the bone nodes themselves, and `blend` never rises above zero here.
float4x4 skin_matrix(Draw draw, Instance instance, uint vid)
{
    float4x4* palette = draw.palette;
    if ((instance.pose & POSE_LIVE) != 0) palette = push.frame[0].live_poses;
    uint base = instance.pose & POSE_MASK;

    uint4 joints = draw.joints[vid];
    float4 weights = draw.weights[vid];

    float4x4 pose = blend_joints(palette, base, joints, weights);
    // Uniform across an instance, so this is a scalar branch: a crowd that is not
    // fading pays one compare and reads one palette.
    if (instance.blend <= 0.0) return pose;

    float4x4 from = blend_joints(palette, instance.pose_from & POSE_MASK, joints, weights);
    return pose + (from - pose) * instance.blend;
}

// The surface maths this file and `material.slang` would otherwise carry twice —
// `shaders/surface.slang`, spliced in here by `shader_source`. `mapped_normal_frame`
// is what makes binding 3 mean anything, and `variant_uv` is what the vertex
// stage below lays a per-copy uv with.
//
// **Above both entry points and not beside the lighting it is mostly used by**,
// which is where it sat until a vertex stage needed one of its functions: Slang
// wants a declaration before its use, and a marker that has to move whenever a
// shared function finds a second caller is a marker in the wrong place.
//@shared


struct VertexOutput
{
    float3 normal : NORMAL;
    float2 uv : TEXCOORD0;
    // Where this fragment is in the world.
    //
    // **This shader had no such varying until shadows existed**, and its absence
    // was documented as a positive statement: `material.slang`'s copy still says
    // "mesh.slang carries no world position because nothing it computes needs
    // one". A shadow lookup is exactly a thing that needs one — the light's
    // matrix has to be applied to a world position and there is nowhere else to
    // get it — so the sentence stopped being true and the varying arrived. Same
    // semantic and same slot as `material.slang`'s, which is what keeps the two
    // sets of varyings the parallel pair its header claims they are.
    float3 world : TEXCOORD1;
    // The instance's own colour, carried to the fragment stage because that is
    // where albedo is assembled. Interpolating it is a no-op — it is constant
    // across every vertex of an instance — and it is not marked
    // `nointerpolation` so that the two shaders declare the same varyings in the
    // same order, which `material.slang`'s header explains is a wire format
    // rather than a coincidence.
    float4 color : COLOR0;
    // glTF's COLOR_0, white when the mesh carries none.
    //
    // **This used to say `mesh.slang` had no counterpart to `material.slang`'s
    // COLOR1**, on the argument that a colour attribute changes no pixel without
    // a body to read it. That was true while nothing here read it and stopped
    // being true when this shader started multiplying it into albedo: glTF
    // defines COLOR_0 as a linear factor on the base colour, Three.js's loader
    // turns `vertexColors` on for a primitive that has one, and a file that
    // arrived painted was rendering grey. The cost is one interpolated float4 on
    // every draw, paid whether or not the mesh has the attribute, because a
    // varying is part of the pipeline rather than of the draw.
    float4 vertex_color : COLOR1;
    // This copy's place in the lightmap atlas: xy the atlas uv of this fragment,
    // z 1 where there is a tile and 0 where there is not. Affine in the mesh's own
    // uv, so interpolating it here is exact rather than a shortcut.
    float3 lightmap : TEXCOORD4;
    float4 sv_position : SV_Position;
};

// The base vertex, displaced by every morph target this bucket carries.
//
// **Before the skin and never after.** A blend shape is authored against the rest
// mesh — the modeller moved those vertices with the character in its bind pose —
// so displacing a vertex the joints have already moved would apply a rest-space
// offset in posed space, and the correction would swing with the limb. glTF says
// the same thing in the same order: morph, then skin, then the model matrix.
//
// A loop rather than a fixed set of slots, because a face is twenty targets and a
// flag is two. The count is uniform across a draw, so this is one loop and not
// divergence, and it does not run at all when `morph_targets` is zero — which is
// every bucket in most frames, and every pre-skinned bucket always, because the
// compute pass did this already.
void apply_morph(Draw draw, Instance instance, uint vid, inout float3 position, inout float3 normal)
{
    if (draw.morph_targets == 0 || instance.morph == 0) return;

    // Stored plus one, so zero can mean "this copy does not morph" — which is what
    // a copy whose weights were cleared carries, and every copy of every unmorphed
    // mesh with it.
    uint base = instance.morph - 1;

    for (uint t = 0; t < draw.morph_targets; t++)
    {
        float weight = push.frame[0].morph_weights[base + t];
        // Skipped rather than multiplied by zero: a face wears two of its twenty
        // expressions, so the branch is taken far more often than not and costs one
        // compare against two multiply-adds and a 24-byte read.
        if (weight == 0.0) continue;

        MorphDelta delta = draw.morph[t * draw.skin_stride + vid];
        position += weight * delta.position;
        normal += weight * delta.normal;
    }
}

[shader("vertex")]
VertexOutput vertexMain(uint vid : SV_VertexID, uint iid : SV_InstanceID)
{
    VertexOutput output;

    Draw draw = push.draw[0];
    Instance instance = push.instances[iid];

    float3 position = draw.positions[vid];

    // An `if` rather than a ternary: a ternary lets the compiler evaluate both
    // sides and load through the null pointer it was meant to avoid.
    float3 normal = float3(0.0, 1.0, 0.0);
    if ((draw.flags & FLAG_HAS_NORMALS) != 0) normal = draw.normals[vid];

    // White is the identity for the multiply in the fragment stage, so a mesh
    // with no colour attribute and a mesh painted white are the same surface —
    // which is what lets the fragment stage multiply unconditionally and carry
    // no second branch. Same rule and same sentence as `material.slang`'s.
    output.vertex_color = float4(1.0, 1.0, 1.0, 1.0);
    if ((draw.flags & FLAG_HAS_COLORS) != 0) output.vertex_color = draw.colors[vid];

    apply_morph(draw, instance, vid, position, normal);

    // The two ways a vertex gets posed, and a bucket is at most one of them.
    //
    // **Before the model matrix either way**, because a joint matrix is in the
    // character's own space and the model matrix is what puts the character in the
    // world. Doing it the other way round poses the mesh around the world origin,
    // which looks like a rig that explodes the moment the character walks away
    // from it.
    if ((draw.flags & FLAG_HAS_SKIN) != 0)
    {
        float4x4 pose = skin_matrix(draw, instance, vid);
        position = mul(pose, float4(position, 1.0)).xyz;
        normal = mul((float3x3)pose, normal);
    }
    else if ((draw.flags & FLAG_PRESKINNED) != 0)
    {
        // The compute pass already did the blend, once per vertex per frame rather
        // than once per vertex per draw. It wrote one copy of the mesh per
        // instance, so the index carries the instance as well as the vertex.
        SkinnedVertex skinned = draw.posed[iid * draw.skin_stride + vid];
        position = skinned.position;
        normal = skinned.normal;
    }

    float4 world = mul(instance.model, float4(position, 1.0));
    output.sv_position = mul(push.frame[0].view_projection, world);
    output.world = world.xyz;
    output.normal = mul((float3x3)instance.normal, normal);

    output.uv = float2(0.0, 0.0);
    if ((draw.flags & FLAG_HAS_UVS) != 0) output.uv = draw.uvs[vid];

    // The mesh's own TEXCOORD_0, before `variant_uv` moves it — the coordinate the
    // bake rasterised in, and so the only one that indexes the tile.
    float2 lightmap_uv = float2(0.0);
    if (draw.lightmap_uvs) lightmap_uv = draw.lightmap_uvs[vid];
    output.lightmap = float3(
        instance.lightmap.xy + lightmap_uv * instance.lightmap.zw,
        instance.lightmap.z > 0.0 ? 1.0 : 0.0
    );
#ifdef THREE_LIGHTMAP_BAKE
    // The bake rasterises in uv space: a texel of the tile is a point of the
    // surface, and the world position and normal cross into the fragment stage
    // exactly as they would in a frame. The viewport is what puts the square in
    // this copy's tile — see `render/lightmap.c3`.
    output.sv_position = float4(lightmap_uv * 2.0 - 1.0, 0.0, 1.0);
#endif
    // This copy's own uv, before the fragment stage's repeat and offset —
    // `variant_uv` in `surface.slang`, and `plan.md` §27 for why a per-copy uv is
    // what a row of one shape needs to stop reading as a row of one picture.
    //
    // **Here rather than in the fragment stage**, unlike `uv_transform`, which is
    // exact and not a shortcut: every operation in `variant_uv` is affine in uv,
    // and an affine map commutes with the linear interpolation between here and
    // there. So this is the same picture for three vertices' worth of work
    // instead of a screen's, and it needs no varying of its own.
    //
    // Clamped against this table's own length and not against `MATERIAL_ROWS`:
    // one channel indexes two tables that have no reason to be the same size.
    if (draw.uv_variant_count != 0u)
    {
        output.uv = variant_uv(output.uv, draw.uv_variants[min(instance.variant, draw.uv_variant_count - 1u)]);
    }

    output.color = instance.color;

    return output;
}

// **The sRGB decode: what it is applied to, and what it is deliberately not.**
//
// Two colours multiply into albedo below and they are in *different spaces*,
// which looks like an inconsistency and is the only arrangement that is correct.
//
// `push.base_color` is the mesh's own factor, and it comes from a glTF
// `baseColorFactor`, which the specification defines as **linear**. Decoding it
// would be decoding something twice, and would make a round trip through
// `scene.export` darken a scene every time it was written and read back.
//
// `input.color` is the copy's own tint, and it comes from `mesh.color` in a
// script — a hex a person read off a colour picker, which is **sRGB**. Using it
// raw is what made `examples/village` need every generated texel pre-corrected
// by hand.
//
// So the mesh's factor is used as it arrives and the script's is decoded.
// `scene/primitive.c3` states `PRIMITIVE_COLOR` in sRGB for readability and
// converts where it is assigned, which is the same rule seen from the other
// side.
//
//
// `gpu/target.c3` renders to an `R8G8B8A8_SRGB` target, so the hardware encodes
// on write. That fixes the output half of the round trip and leaves the input
// half: a colour a script hands over — `mesh.color = 0xff8040`, a `[r,g,b]`
// triple, a `scene.background` — is a value someone read off a colour picker,
// which is to say an sRGB one. Multiplying it into linear lighting arithmetic
// untouched is the same category of error the target used to make, pointing the
// other way, and it would leave a hex value rendering as a visibly different
// colour from the hex.
//
// Textures need no equivalent because the sampler already does it: they upload
// as `R8G8B8A8_SRGB` (`gpu/texture.c3`) and arrive linear. So after this one
// call every term in the multiply below is linear, which is the property the
// lighting arithmetic has always assumed and never actually had.
//
// It is per fragment rather than per instance on the CPU because it is free
// here and because the two shaders then cannot disagree. `scene/export.c3`
// makes the same conversion for glTF's `baseColorFactor`, which is defined
// linear — that is the third copy and the reason this text names it.
//
// **The exact piecewise curve, not `pow(c, 2.2)`.** The approximation looks
// harmless measured against the real curve — about 3 eight-bit levels at worst —
// and is not, because the device is not negotiable: the `_SRGB` attachment
// encodes with the exact curve whatever this decoded with. Decode by
// approximation and encode by hardware and a value comes back **wrong by up to
// 9 levels, worst around 15/255**, which is a visible step in the part of the
// range where banding already lives. `three_tests::color` measures it.
float3 srgb_to_linear(float3 c)
{
    float3 lo = c / 12.92;
    float3 hi = pow(max(c + 0.055, 0.0) / 1.055, 2.4);
    return lerp(hi, lo, step(c, 0.04045));
}

float shadow_view_factor(uint index, float3 position, float3 normal)
{
    return shadow_view_factor_filtered(index, position, normal, 1.0);
}

float shadow_factor(float3 position, float3 normal)
{
    return shadow_view_factor(push.frame[0].lights[0].meta.y, position, normal);
}

float shadow_debug_depth(float2 local)
{
    uint index = push.frame[0].lights[0].meta.y;
    if (index == 0xffffffffu) return 1.0;
	ShadowGpuView view = push.frame[0].shadow_views[index];
	if (view.params.w <= 0.0) return 1.0;
	return shadow_atlas.SampleLevel(saturate(local) * view.atlas.xy + view.atlas.zw, 0.0).r;
}

// This fragment's shadow, looked up once and left where `lambert` can reach it.
//
// The same global `material.slang` carries, for the same reason and with the same
// lifetime: written once in `fragmentMain` before anything shades, read once in
// `lambert`. See that file, which has the account of why the factor is not an
// argument.
static float g_shadow = 1.0;

// This fragment's world position, left where `lambert` can reach it.
//
// **The same lifetime and the same argument as `g_shadow` beside it**: written
// once in `fragmentMain` before anything shades, read in `lambert`. It exists
// because a light may be a *place* — `light_toward` needs to know where the
// surface is to work out which way a point light is and how much of it arrives —
// and `lambert(float3 normal)` is how every body ever written spells the call.
// Adding a parameter would have left every one of them compiling and lit by the
// directional lights alone, which is a scene missing a campfire and no diagnostic
// anywhere. `specular_light` already takes the position and uses its own.
static float3 g_position = float3(0.0, 0.0, 0.0);
static float3 g_receiver_normal = float3(0.0, 1.0, 0.0);
static float4 g_screen_position = float4(0.0);
static float g_crevice = 1.0;
// This fragment's baked light, read once out of the atlas, and whether there was
// a tile to read it from. Zero and false on every dynamic receiver and on every
// mesh whose uvs could not carry a tile, which is what keeps a baked light shaded
// in real time wherever it was never baked.
static float3 g_lightmap = float3(0.0);
static bool g_lightmapped = false;
//@lighting

uint fragment_cluster()
{
    return shared_fragment_cluster(push.frame,g_screen_position,g_position);
}

float area_diffuse(Light light, float3 position, float3 normal)
{
    return shared_area_diffuse(light,position,normal);
}

bool cluster_contains(uint lightIndex)
{
    return shared_cluster_contains(push.frame,fragment_cluster(),lightIndex);
}

float3 area_specular_term(Light light, float3 position, float3 normal, float3 view,
    float3 f0, float f90, float a2, float k, float nDotV)
{
    return shared_area_specular(light,position,normal,view,f0,f90,a2,k,nDotV);
}

// Visibility from point-light `index`. Cube faces use a conventional 90 degree
// perspective projection, whose depth is a function of the face-forward
// distance (the largest absolute component), not radial distance.
float point_shadow_factor(uint index, Light light, float3 position, float3 normal)
{
    return shared_point_shadow_factor(index, light, position, g_receiver_normal);
}


// The direct light reaching this point, as a colour.
//
// **The same function, character for character, in `mesh.slang` and in
// `material.slang`** — for the reason `srgb_to_linear` and `shadow_factor` are
// duplicated, which is that a material is a change of *shading* and not a second
// renderer. A body of `s.albedo * lambert(s.normal)` has to draw what a mesh with
// no material at all draws.
//
// **A colour rather than a factor**, now that a light has a colour. `s.albedo *
// lambert(s.normal)` did not change meaning — a float3 times a float3 is the
// per-channel product it always was — and the one thing that stops compiling is a
// body that assigned the answer to a `float`.
//
// **The shadow multiplies the direct term and not the ambient floor.** A surface
// in shadow still gets the floor, which is what keeps a shadowed face readable
// rather than black — the same argument the floor exists for at all. Multiplying
// the whole result instead would make `three.light.ambient` mean nothing wherever
// a shadow fell.
//
// Each light names its shadow-atlas view through stable metadata.
//
// **`occlusion` multiplies the ambient floor and the world light, and nothing
// else** — the two terms that arrive from everywhere — which is the one thing
// about an occlusion map that is easy to get wrong and looks plausible either
// way. An AO map records how much of the *sky* a crevice can see; it says
// nothing about a lamp, and a lamp shining straight into that crevice lights it.
// Applied to the direct term as well it reads as dirt painted into the wrong
// places — darkest exactly where a light is pointing — and the mistake survives
// review because a dirty crevice looks like a dirty crevice. `environment_light`
// is scaled by the same number at the call site, for the same reason: it is the
// other term that arrives from everywhere.
float3 lambert(float3 normal, float occlusion)
{
    float ambient = push.frame[0].lighting.x;
    uint count = (uint)push.frame[0].lighting.y;
    float3 direct = float3(0.0, 0.0, 0.0);
    // Directional emitters are global. Local lights come from
    // this fragment's cluster; an overflow bit deliberately falls back to the
    // all-light reference path rather than dropping illumination.
    for (uint i = 0u; i < count; i++)
    {
        Light light = push.frame[0].lights[i];
        if (light.meta.z != 0u) continue;
        if (g_lightmapped && shared_light_is_baked(light)) continue;
        float reach;
        float3 to_light = light_toward(light.direction, g_position, reach);
        float n_dot_l = max(dot(normal, to_light), 0.0) * reach;
        if (n_dot_l <= 0.0) continue;
        if (i == 0u) n_dot_l *= g_shadow;
        else n_dot_l *= point_shadow_factor(i, light, g_position, normal);
        direct += light.color.rgb * light.color.w * n_dot_l;
    }
    uint cluster = fragment_cluster();
    uint packedCount = push.frame[0].cluster_grid.w==0u?0x80000000u:push.frame[0].cluster_counts[cluster];
    bool overflow = (packedCount & 0x80000000u) != 0u;
    uint localCount = overflow ? count : packedCount;
    for (uint k = 0u; k < localCount; ++k)
    {
        uint i = overflow ? k : push.frame[0].cluster_indices[cluster * push.frame[0].cluster_grid.w + k];
        Light light = push.frame[0].lights[i];
        if (g_lightmapped && shared_light_is_baked(light)) continue;
        // Nothing is sampled for a light already at zero: the shadow only scales
        // what the light delivers, and an area emitter out of range delivers none.
        if (light.meta.z == 2u || light.meta.z == 3u) { float area = area_diffuse(light,g_position,normal); if (area <= 0.0) continue; direct += light.color.rgb*area*point_shadow_factor(i,light,g_position,normal); continue; }
        if (light.meta.z != 1u && light.meta.z != 4u) continue;
        float reach;
        float3 to_light = light_toward(light.direction, g_position, reach);
        if(light.meta.z==4u)reach*=shared_spot_reach(light,to_light);
        float n_dot_l = max(dot(normal, to_light), 0.0) * reach;
        if (n_dot_l <= 0.0) continue;
        n_dot_l *= point_shadow_factor(i, light, g_position, normal);
        direct += light.color.rgb * light.color.w * n_dot_l;
    }
    // The tile carries exactly the terms the loops above skipped, so adding it
    // here rather than at the end is what makes a baked light and a real-time one
    // the same picture.
    if(g_lightmapped)direct+=max(g_lightmap
        +shared_baked_dynamic_delta(push.frame,normal,g_receiver_normal,g_position),float3(0.0));
    float ambient_visibility = occlusion * g_crevice;
    return ambient * ambient_visibility + (1.0 - ambient) * direct + push.frame[0].world.rgb * ambient_visibility;
}

// The same light with nothing occluding it, which is every caller that has no
// map — and every `ShaderMaterial` body ever written, all of which spell it
// `lambert(s.normal)`.
float3 lambert(float3 normal)
{
    return lambert(normal, 1.0);
}

// The specular highlight, over the same lights `lambert` sums the diffuse over.
//
// **The same function, character for character, in `mesh.slang` and in
// `material.slang`**, for `lambert`'s reason.
//
// Cook-Torrance: a GGX distribution, Smith's masking under the Schlick-GGX
// approximation, and Schlick's Fresnel with Filament's `f90`. Those four names
// are here because the constants below are unreadable without them, and the
// mapping from `reflectance` to `f0` is Filament's too — 0.5 is the 4% that
// ordinary dielectrics reflect and 1 is about the most any of them do.
//
// **A default material's highlight is exactly zero, not merely small.** That is
// what `f90` buys: with `reflectance` at 0 the plain Schlick term would still
// climb to 1 at a grazing angle, which would have put a rim of light on every
// surface in every scene already written against a Lambert renderer. Filament's
// `f90` collapses with `f0`, so the term is off until something asks for it —
// `scene/material.c3` has why that is the default rather than the 4%.
//
// **Metalness kills the diffuse rather than tinting it.** A metal reflects and
// does not scatter, so `standard` scales the albedo by `1 - metalness` and the
// colour comes back through `f0`. With no environment map to reflect, a fully
// metallic surface is therefore its highlights and nothing else — dark, and
// correctly so. `scene.environment` is what gives it something to reflect, and
// `environment_light` below is the term that reads it.
float3 specular_light(float3 normal, float3 position, float3 albedo, float roughness, float metalness, float reflectance)
{
    float3 view = normalize(push.frame[0].camera.xyz - position);
    float3 f0 = lerp(float3(0.16 * reflectance * reflectance), albedo, metalness);
    float f90 = clamp(dot(f0, float3(16.5, 16.5, 16.5)), 0.0, 1.0);
    // Away from a perfect mirror: at zero roughness the GGX lobe is a spike, and a
    // light with no area to reflect lands on either no fragment or one.
    float a = max(roughness * roughness, 1e-3);
    float a2 = a * a;
    float n_dot_v = max(dot(normal, view), 1e-4);
    float k = a * 0.5;

    float3 sum = float3(0.0, 0.0, 0.0);
    uint count = (uint)push.frame[0].lighting.y;
    for (uint i = 0u; i < count; i++)
    {
        Light light = push.frame[0].lights[i];
        if (light.meta.z != 0u && !cluster_contains(i)) continue;
        // The lightmap holds diffuse only. Highlights remain view-dependent and
        // therefore stay in this real-time loop for baked lights as well.
        if (light.meta.z == 2u || light.meta.z == 3u) { float3 area = area_specular_term(light,position,normal,view,f0,f90,a2,k,n_dot_v); if (dot(area, float3(1.0)) <= 0.0) continue; sum += area*point_shadow_factor(i,light,position,normal); continue; }
        float reach;
        float3 to_light = light_toward(light.direction, position, reach);
        if(light.meta.z==4u)reach*=shared_spot_reach(light,to_light);
        float n_dot_l = max(dot(normal, to_light), 0.0);
        if (n_dot_l * reach <= 0.0) continue;

        float3 half_vector = normalize(to_light + view);
        float n_dot_h = max(dot(normal, half_vector), 0.0);
        float v_dot_h = max(dot(view, half_vector), 0.0);

        float denominator = n_dot_h * n_dot_h * (a2 - 1.0) + 1.0;
        float distribution = a2 / (3.14159265 * denominator * denominator);
        float geometry = (n_dot_l / (n_dot_l * (1.0 - k) + k)) * (n_dot_v / (n_dot_v * (1.0 - k) + k));
        float3 fresnel = f0 + (float3(f90, f90, f90) - f0) * pow(1.0 - v_dot_h, 5.0);

        // The shadow multiplies the light rather than the geometry term, unlike in
        // `lambert` where the two are the same multiply: an occluded light delivers
        // less energy, it does not change the shape of the microfacets.
        float occlusion = i == 0u ? g_shadow : point_shadow_factor(i, light, position, normal);
        sum += light.color.rgb * light.color.w * occlusion * reach
             * distribution * geometry * fresnel / (4.0 * n_dot_v);
    }
    return sum;
}


// A world direction to a texel of the equirectangular environment image, with
// the frame's sky rotation applied.
//
// **The same mapping and the same rotation as `shaders/sky.slang`**, which is
// the whole point of `environment.y` being a frame field: a metal that reflected
// an unrotated sky while the background drew a rotated one would be wrong in a
// way that only shows when somebody turns it.
float2 environment_uv(float3 direction)
{
    const float ENVIRONMENT_PI = 3.14159265358979;
    float angle = push.frame[0].environment.y;
    float s = sin(angle);
    float c = cos(angle);
    float3 turned = float3(
        c * direction.x - s * direction.z, direction.y, s * direction.x + c * direction.z
    );
    float u = atan2(turned.x, -turned.z) / (2.0 * ENVIRONMENT_PI) + 0.5;
    float v = acos(clamp(turned.y, -1.0, 1.0)) / ENVIRONMENT_PI;
    return float2(u, v);
}

// The environment's contribution to a surface, which is the reflection and
// nothing else.
//
// **This is what makes a metal look like metal.** `specular_light` sums over the
// four punctual lights, and a metal has no diffuse to fall back on — `standard`
// scales the albedo by `1 - metalness` — so a fully metallic surface with no sky
// is its highlights and a great deal of black. What it is missing is everything
// it should be reflecting, and this is that.
//
// **The reflection and not the irradiance.** A full image-based light also feeds
// the diffuse half from the same image, and deliberately does not here: the
// diffuse floor in this renderer is `three.light.ambient`, a scene already sets
// it, and adding a second one would light every existing scene twice the moment
// somebody set a sky. The reflection has no such double — nothing else in this
// shader produces one.
//
// `roughness` picks a mip level rather than integrating a lobe, which is the
// approximation every real-time renderer makes and is why `environment.z`
// carries the chain length. A rough surface reflects a blurred sky; a smooth one
// reflects the texels. The Fresnel is Schlick's with roughness folded into the
// grazing term, so a rough metal does not turn into a mirror at the silhouette.
float3 environment_light(float3 normal, float3 position, float3 albedo, float roughness, float metalness, float reflectance)
{
    float intensity = push.frame[0].environment.x;
    if (intensity <= 0.0) return float3(0.0, 0.0, 0.0);

    float3 view = normalize(push.frame[0].camera.xyz - position);
    float3 reflected = reflect(-view, normal);

    float3 f0 = lerp(float3(0.16 * reflectance * reflectance), albedo, metalness);
    float n_dot_v = max(dot(normal, view), 1e-4);
    float3 grazing = max(float3(1.0 - roughness), f0);
    float3 fresnel = f0 + (grazing - f0) * pow(1.0 - n_dot_v, 5.0);

    float lod = clamp(roughness, 0.0, 1.0) * push.frame[0].environment.z;
    float3 sky = environment_map.SampleLevel(environment_uv(reflected), lod).rgb;
    return sky * fresnel * intensity;
}



// **The debug views, and the whole of `plan.md` §20.2's first two items.**
//
// A frame with no visible shadows in it has three explanations and the renderer
// used to distinguish none of them: the pass did not run, the pass ran and the
// fit is somewhere else, or everything visible is genuinely inside one big
// shadow. The plan's level spent about an hour on the third, and settled it by
// decoding a PNG in Python and averaging the luminance of the lower third of the
// frame. Each of these is that hour as one render.
//
//   1  'shadow'      — `shadow_factor` as greyscale. White is lit, black is
//                      fully shadowed. A frame that is uniformly white is a pass
//                      that did not run or a fit nothing landed in; a frame that
//                      is uniformly dark is the answer that took the hour.
//   2  'shadowMap'   — the depth the lookup would read at this fragment, as
//                      greyscale near-to-far, which is the map itself seen
//                      through the geometry that samples it. **Magenta is
//                      outside the fitted box**, and that is the diagnostic: a
//                      frame that is mostly magenta is a `shadow.distance` fitted
//                      somewhere other than where the author is looking. Dark
//                      purple is "no shadow pass ran this frame" — the one
//                      answer the other view cannot distinguish from "lit".
//
// The sky is not a surface and has no shadow, so a debug view colours only what
// the geometry covers. That is a property of doing this in the shading pass and
// not a limitation worth plumbing around: the question is always about a
// surface.
//
// @param answer : `The colour to draw instead, when the return is true.`
// @return `true when this frame is a debug view and the shading should not be used.`
bool debug_view(float3 position, float3 normal, out float3 answer)
{
    float mode = push.frame[0].debug.x;
    answer = float3(0.0);
    if (mode < 0.5) return false;

    if (mode < 1.5)
    {
        answer = float3(shadow_factor(position, normal));
        return true;
    }

    float4 params = push.frame[0].shadow;
    if (params.w <= 0.0)
    {
        answer = float3(0.16, 0.0, 0.28);
        return true;
    }

    // No normal offset here, unlike the lookup: this view answers "where does
    // this fragment land in the map", and nudging it two texels first would
    // answer about a point next to the one being asked about.
    float4 clip = mul(push.frame[0].light_view_projection, float4(position, 1.0));
    float3 ndc  = clip.xyz / clip.w;
    float2 uv   = float2(0.5 + 0.5 * ndc.x, 0.5 - 0.5 * ndc.y);
    if (uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0 || ndc.z < 0.0 || ndc.z > 1.0)
    {
        answer = float3(1.0, 0.0, 1.0);
        return true;
    }

    answer = float3(shadow_debug_depth(uv));
    return true;
}

// `front_facing` is a parameter rather than a field of `VertexOutput`: that struct
// is the vertex stage's output as well as this stage's input, and a system value
// the rasteriser produces has no meaning there. `material.slang` declares it the
// same way, for the same reason.
#ifdef THREE_LIGHTMAP_BAKE
// The bake's whole fragment stage: the direct diffuse of the baked lights at this
// point of the surface, and nothing else. No albedo, because a tile is light
// rather than colour; no specular, because a highlight is a fact about where the
// camera is; no material body, because none of them changes where a light is.
//
// A body that displaces its vertices or discards part of its quad therefore bakes
// as the mesh the file holds — `docs/functions.md` says so.
[shader("fragment")]
float4 fragmentMain(VertexOutput input, bool front_facing : SV_IsFrontFace) : SV_Target
{
    // The interpolated normal for both the shading and the shadow lookup. The
    // frame offsets its shadow sample along the *face* normal instead, from the
    // derivatives of the world position — measured on the reference scene the two
    // answer the same thing here, and a uv-space derivative is degenerate on a
    // triangle with no area in uv, which is a NaN this cannot afford.
    float3 geometric = normalize(input.normal);
    float3 normal = geometric;
    Draw draw = push.draw[0];
    if ((draw.flags & (FLAG_HAS_UVS | FLAG_HAS_NORMAL_MAP)) ==
        (FLAG_HAS_UVS | FLAG_HAS_NORMAL_MAP))
    {
        float2 uv = input.uv * draw.uv_transform.xy + draw.uv_transform.zw;
        Map normal_map = map_at(SLOT_NORMAL);
        float3 texel = (draw.flags & FLAG_STOCHASTIC) != 0
            ? stochastic_sample(normal_map, uv).rgb
            : normal_map.Sample(uv).rgb;
        normal = mapped_normal_frame(geometric, input.world, uv, texel);
    }
    return float4(shared_baked_diffuse(push.frame, normal, geometric, input.world), 1.0);
}
#else
[shader("fragment")]
float4 fragmentMain(VertexOutput input, bool front_facing : SV_IsFrontFace) : SV_Target
{
    g_screen_position = input.sv_position;
    // The tile, read once. `Instance.lightmap` is zero-sized on every copy that has
    // no tile, which the vertex stage turned into a zero here.
    // **Front faces only.** A double-sided surface is shaded with its normal turned
    // toward the eye, so a leaf card lit from one side and seen from the other is a
    // different answer at the same point of the same triangle — and the tile holds
    // the one the bake rasterised, which is the front. A back face falls back to
    // the whole real-time loop, which is right rather than merely safe.
    g_lightmapped = front_facing && input.lightmap.z > 0.5;
    if (g_lightmapped) g_lightmap = lightmap_atlas.SampleLevel(input.lightmap.xy, 0.0).rgb;
    // The instance's colour multiplies the material's, so `mesh.color = [1, 0,
    // 0]` works with no material at all — which is the point of it being here
    // rather than only in `material.slang`. White is the identity and is what
    // every node starts at.
    Draw draw = push.draw[0];

    // Hoisted, because four maps sample at it now rather than one. The same
    // expression `material.slang` builds for `Surface.uv`, so a body reading
    // `s.uv` and this shader's own sampling land on the same texel.
    float2 uv = input.uv * draw.uv_transform.xy + draw.uv_transform.zw;

    // Three factors, in three spaces, and the asymmetry is the point — see the
    // block above `vertexMain`. The mesh's own is linear and used raw; the
    // instance's came from a script's hex and is decoded; the vertex attribute is
    // linear by the glTF specification and so is used raw as well.
    float3 albedo = draw.base_color.rgb * srgb_to_linear(input.color.rgb);
    // The third factor, and the one that is not always a factor: a COLOR_0 the
    // file painted as a layer mask is a weight per channel and multiplying the
    // texture by it draws the mask. See `FLAG_COLORS_ARE_MASK`.
    if ((draw.flags & FLAG_COLORS_ARE_MASK) == 0) albedo *= input.vertex_color.rgb;

    // The normal the mesh has, kept apart from the one the map bends: the shadow
    // lookup is done with *this* one. A per-texel normal offset would move the
    // sample point with the relief and put acne back where the offset exists to
    // take it away — and `material.slang` looks the shadow up with `s.normal` for
    // the same reason, so the two shaders shadow a surface identically.
    float3 geometric = normalize(input.normal);
    // **A back face is shaded with its normal turned toward the eye**, which is
    // Blender's rule and every other renderer's. Only a double-sided material
    // ever rasterises one — `material.side` picks the cull mode, so a single
    // sided draw never reaches this line with `front_facing` false — and the
    // face the eye can see is by definition the lit side of a leaf, a sheet of
    // cloth, or a slab the file wound inside-out. Taken as it came, `n·l` is
    // negative and the surface is black; worse, `shadow_factor` lifts its
    // sample along this normal and so lifts it *into* the slab, and the wall
    // shadows itself. The shadow pass reads no normal and needs none of this.
    if (!front_facing) geometric = -geometric;
    float3 normal = geometric;
    float4 surface = draw.surface;
    float occlusion = 1.0;
    // What this surface gives off on its own, before a map has multiplied it.
    // Zero on every material nobody set one on, and the add at the bottom is then
    // an add of nothing.
    float3 emissive = draw.emissive.rgb;

    // **One test for all four maps.** A map is a picture laid on a surface by its
    // uvs, and a mesh with none — a convex hull, a debug line — has nowhere to
    // put any of them. Nested rather than four separate tests so that stays one
    // statement rather than four places to forget it.
    //
    // Every branch below is uniform across the draw: the flags come off the
    // bucket's record, so a quad never splits and the derivatives inside
    // `mapped_normal_frame` are as well defined as the ones `Sample` takes here.
    if ((draw.flags & FLAG_HAS_UVS) != 0)
    {
        // The one branch, read once: every map below goes through the same
        // sampler as the albedo or none of them does. Uniform across the draw —
        // it is a bit off the bucket's record — so this costs no divergence and
        // the derivatives inside `stochastic_sample` are as well defined as the
        // ones a plain `Sample` takes.
        bool scattered = (draw.flags & FLAG_STOCHASTIC) != 0;

        Map base_color_map = map_at(SLOT_BASE_COLOR);
        float4 base = scattered ? stochastic_sample(base_color_map, uv) : base_color_map.Sample(uv);

        // **`material.alphaTest`, and the whole of it in the colour pass.** The
        // threshold is `w` of the record's surface, zero on every material that
        // never asked for a cut-out — and zero can discard nothing, because no
        // alpha is below it. So there is no flag, no second pipeline and no
        // branch here: a scene with no foliage in it pays one compare that is
        // always false.
        //
        // The alpha is the map's times the material's own, and *not* times
        // `input.color.a`. A cut-out is a property of the picture painted on the
        // surface, so fading one copy of a leaf card out with `mesh.color` has to
        // fade it rather than dissolve it — and the shadow pass, which has no
        // per-copy colour to read, then cuts the same shape this does.
        if (base.a * draw.base_color.a < draw.surface.w) discard;

        albedo *= base.rgb;

        if ((draw.flags & FLAG_HAS_NORMAL_MAP) != 0)
        {
            Map normal_map = map_at(SLOT_NORMAL);
            float3 texel = scattered
                ? stochastic_sample(normal_map, uv).rgb
                : normal_map.Sample(uv).rgb;
            normal = mapped_normal_frame(geometric, input.world, uv, texel);
        }

        // glTF's channels: green is roughness, blue is metalness. **Multiplied
        // into the material's own two rather than replacing them**, which is what
        // glTF says `roughnessFactor` and `metallicFactor` mean and what every
        // other renderer does — so a file's factors and its map compose, and the
        // importer hands both over without either having to know about the other.
        //
        // The consequence worth knowing is on the other side of that multiply:
        // this renderer's default metalness is 0, so a map on a material nobody
        // set `metalness` on is multiplied away. `material.metalness = 1` is what
        // lets the map's blue speak, and it is what glTF's own default already
        // says.
        if ((draw.flags & FLAG_HAS_METALNESS_ROUGHNESS_MAP) != 0)
        {
            Map metalness_roughness_map = map_at(SLOT_METALNESS_ROUGHNESS);
            float2 pair = scattered
                ? stochastic_sample(metalness_roughness_map, uv).gb
                : metalness_roughness_map.Sample(uv).gb;
            surface.x *= pair.x;
            surface.y *= pair.y;
        }

        if ((draw.flags & FLAG_HAS_OCCLUSION_MAP) != 0)
        {
            Map occlusion_map = map_at(SLOT_OCCLUSION);
            occlusion = scattered
                ? stochastic_sample(occlusion_map, uv).r
                : occlusion_map.Sample(uv).r;
        }

        // The map multiplies the factor, which is glTF's rule and the same one
        // the metallic-roughness pair follows: the file states both and they
        // compose. The consequence is the same too — a material with a map and
        // no `emissive` colour set glows black, because the factor it is
        // multiplied by is zero. `js/prelude/material.js` is where a map with no
        // colour beside it takes white.
        if ((draw.flags & FLAG_HAS_EMISSIVE_MAP) != 0)
        {
            Map emissive_map = map_at(SLOT_EMISSIVE);
            emissive *= scattered
                ? srgb_to_linear(stochastic_sample(emissive_map, uv).rgb)
                : srgb_to_linear(emissive_map.Sample(uv).rgb);
        }
    }

    // Once, here, and then left in `g_shadow` for `lambert` to fold into the
    // direct term — the same shape `material.slang` uses, so the two files do the
    // lookup the same number of times as well as the same way.
    g_shadow = shadow_factor(input.world, geometric);
    g_position = input.world;
    float3 faceNormal = normalize(cross(ddx(input.world), ddy(input.world)));
    g_receiver_normal = dot(faceNormal, geometric) < 0.0 ? -faceNormal : faceNormal;
    g_crevice = crevice_occlusion(input.world, geometric);

    // After the normal and before the shading, which is the only place it can
    // be: the views need a world position and a normal, and they answer instead
    // of the shading rather than beside it.
    float3 view;
    if (debug_view(input.world, geometric, view)) return float4(view, 1.0);

    // The material's alpha times this copy's own, exactly as the rgb above
    // multiplies the two. `mesh.color = [r, g, b, a]` therefore fades one
    // instance out of a thousand sharing a draw call — and does nothing at all
    // unless the material was built transparent, because an opaque pipeline
    // discards this channel. It read a hardcoded `1.0` until blending existed.
    // The whole of the built-in shading, and the whole of what `standard(s)` is in
    // `material.slang`: a diffuse half the metalness takes away and a specular
    // half the metalness gives back through `f0`. Both are the identity on a
    // material nobody set — roughness 1, metalness 0, reflectance 0 — so this is
    // still `albedo * lambert(normal)` for every scene written before the term
    // existed.
    //
    // **The occlusion map reaches two of the three terms**, and which two is the
    // whole of getting it right: the ambient floor inside `lambert`, and the
    // environment reflection here. Not the direct lobes — `lambert`'s own header
    // has the argument, and the short version is that a lamp pointed into a
    // crevice lights it.
    SharedLightTerms direct = shared_standard_lights(
        push.frame, g_screen_position, normal, g_receiver_normal, input.world, albedo,
        surface.x, surface.y, surface.z, g_shadow, g_lightmapped
    );
    float ambient_visibility = occlusion * g_crevice;
    float3 diffuse = push.frame[0].lighting.x * ambient_visibility
        + (1.0 - push.frame[0].lighting.x) * (direct.diffuse
            + (g_lightmapped ? max(g_lightmap
                + shared_baked_dynamic_delta(push.frame,normal,g_receiver_normal,g_position),float3(0.0))
                : float3(0.0)))
        + push.frame[0].world.rgb * ambient_visibility;
    return float4(
        albedo * diffuse * (1.0 - surface.y)
            + direct.specular
            + environment_light(normal, input.world, albedo, surface.x, surface.y, surface.z) * occlusion * g_crevice
            // Added last and reached by nothing above it — not the occlusion, not
            // the shadow, not the metalness. A surface that gives off light gives
            // it off in a crevice, in shadow and on a metal, which is what makes
            // it an emissive rather than a very bright albedo.
            + emissive,
        // The attribute's alpha joins the two the same way its rgb joins the
        // albedo, and drops out under the same flag: a mask's fourth channel is a
        // fourth weight, and a surface painted 0 there is not a surface that was
        // asked to be invisible.
        draw.base_color.a * input.color.a
            * ((draw.flags & FLAG_COLORS_ARE_MASK) != 0 ? 1.0 : input.vertex_color.a)
    );
}
#endif
