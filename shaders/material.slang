// three.c3 material template — `plan.md` §4's tier 2.
//
// **This is a template. It is not valid Slang as it stands and nothing compiles
// it directly.** `src/shader/material_source.c3` reads it, replaces three marker
// lines, and hands the result to `compile_slang` as a string, exactly the way
// `mesh.slang` is read and compiled at startup. Compiling the text below
// unchanged fails on the missing `shade`, and that is the whole division of
// labour: the agent writes one function, three.c3 writes the module around it.
//
// The markers are whole lines, matched after trimming, so their indentation is
// free. Each is replaced by zero or more lines:
//
//     //@uniforms   one field per material uniform, appended to the push block
//     //@rows       `static const uint MATERIAL_ROWS = N;`
//     //@defines    one `#define name (push.name)` per uniform
//     //@shade      `#line`, the agent's fragment body, `#line` back, `#undef`
//
// Everything else is `shaders/mesh.slang` with a world-position varying added
// and the shading lifted out into `shade`. The duplication is deliberate rather
// than lazy: the push block, the descriptor binding and the vertex stage are a
// wire format shared with `gpu/pipeline.c3` and `render/pass.c3`, and a material
// that laid any of them out differently would read geometry from the wrong
// address while still compiling and still rendering something. What keeps the
// two files honest is not this comment — it is
// `the_material_push_block_keeps_the_mesh_contract`, which reflects an assembled
// material and checks it field by field against `MESH_PUSH_FIELDS`.

// **The bake variant.** Replaced by `#define THREE_BAKE 1` when the exporter asks
// for one, and by nothing at all otherwise — so an ordinary material's generated
// source is byte for byte what it was before this existed, the same rule
// `//@table` follows.
//
// It is at the top because of what it guards. A bake is the agent's own body
// rasterised into a texture in uv space, and it has to be *unlit*: a glTF viewer
// lights what it loads, so a baked-in sun would be applied twice. Every function
// below that adds light is therefore two functions, and `vertexMain` places the
// triangle by its uv rather than by the camera. The body itself is unchanged and
// never sees the define — which is what makes this one template rather than a
// second copy of a 44 000-byte shader to keep in step.
//@bake

// One instance: where a copy of the mesh is, how its normals rotate, and the
// three things copies of one mesh may disagree about without costing a draw call.
// Byte for byte what `mesh.slang` and `scene/scene.c3` declare; 152 bytes.
struct Instance
{
    float4x4 model;
    float4x4 normal;
    float4 color;
    uint variant;
    // This copy's joint matrices: an offset in matrices, with POSE_LIVE in the top
    // bit saying which buffer they are in. See `mesh.slang`.
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
};

// One light, byte for byte what `mesh.slang` and `gpu/pipeline.c3` declare.
// Light zero is the sun and the only one that casts; see `mesh.slang`.
struct Light
{
    float4 direction;
    float4 color;
};

// What every draw in the frame shares, written once per frame. 328 bytes, and
// the size is pinned against this declaration by `FRAME_BLOCK_FIELDS` in
// `src/gpu/pipeline.c3` — three files declare this struct and a field added to
// two of them is a buffer read at the wrong offset with nothing to say so.
struct FrameBlock
{
    float4x4 view_projection;
    // x: the ambient floor. y: how many of `lights` are lit this frame.
    // z: game clock seconds (`s.time` / `v.time`). w unused. See `mesh.slang`.
    float4 lighting;
    // This frame's live joint matrices, for characters posed from their bone nodes
    // rather than from a baked clip. One buffer per frame rather than per bucket,
    // which is what keeps a live character and a baked one in the same draw call.
    float4x4* live_poses;
    // The light's own orthographic view-projection, fitted around the scene this
    // frame by `render/shadow.c3` and used at both ends: `shaders/shadow.slang`
    // renders the depth map with it, `shadow_factor` below reads it back.
    float4x4 light_view_projection;
    // x texel, y depth bias, z normal offset, w intensity — and w is zero in a
    // frame with no shadow pass. See `mesh.slang`, which carries the full
    // account of what each of the four is for.
    float4 shadow;
    // `three.debug.view` — x is the mode. See `mesh.slang`, which carries the
    // account of what each mode draws.
    float4 debug;
    // Where the camera is, in world space. Read by the specular term and by
    // nothing else.
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
    // The frame's lights, `lighting.y` of them. At the end of the block so that
    // every offset above it is the one it had when there was a single light.
    Light lights[4];
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
};

// One vertex as the compute pass leaves it, byte for byte what `mesh.slang` and
// `shaders/skin.slang` declare. 24 bytes.
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

// One bucket's geometry and surface, byte for byte what `mesh.slang` and
// `gpu/pipeline.c3`'s `DrawRecord` declare. See `mesh.slang` for what it is and
// why it is a buffer rather than push constants; the short version is that these
// fields used to be pushed, they took 76 of the 128 bytes every device must
// offer, and the material uniforms below had to live in what was left. Skinning
// is what that bought: three of the fields below are streams and a palette that
// could not have been afforded under the old contract at any price.
struct Draw
{
    float3* positions;
    float3* normals;
    float2* uvs;
    // glTF's COLOR_0. Read into `Vertex.vertex_color` and carried to the body;
    // see `Surface.vertex_color` for what it is and what it deliberately is not.
    float4* colors;
    // glTF's JOINTS_0 and WEIGHTS_0. Widened and renormalised on upload; see
    // `mesh.slang`.
    uint4* joints;
    float4* weights;
    // This asset's baked joint matrices, every clip of every skin. See
    // `mesh.slang` and `skin_matrix`.
    float4x4* palette;
    // Where the compute pass wrote this bucket's posed vertices. Separate from
    // `positions` so that `Vertex.local` stays the bind pose whichever path posed
    // the mesh — see `mesh.slang` for why that mattered.
    SkinnedVertex* posed;
    // This mesh's morph targets: `morph_targets` blocks of `vertex_count`
    // displacements each, target-major, so one target's block is contiguous and
    // the loop below walks it with one stride. Null on every mesh without them,
    // which is nearly all of them.
    MorphDelta* morph;
    // rgb: albedo factor. a: the material's opacity, folded into the mesh's own
    // alpha on the C3 side. `fragmentMain` multiplies it by the instance's.
    float4 base_color;
    uint flags;
    // The mesh's vertex count, read only under FLAG_PRESKINNED. See `mesh.slang`.
    uint skin_stride;
    // How many of `morph`'s blocks to apply, and how many weights this bucket's
    // instances read. **Zero is the whole test** — a mesh with no targets, a soft
    // bucket, or a frame with no weight buffer all arrive here as zero and the
    // loop does not run.
    uint morph_targets;
    // xy repeat, zw offset. See `mesh.slang`.
    float4 uv_transform;
    // What the light does when it hits, as opposed to what colour it finds
    // there: x roughness, y metalness, z reflectance, w unused.
    //
    // `{1, 0, 0, 0}` is a matte dielectric with no highlight at all, which is
    // what every material is until a script says otherwise, and is exactly the
    // surface this renderer had before there was a specular term. See
    // `scene/material.c3`, which has why 0 rather than glTF's own defaults.
    float4 surface;
};

// **The three mesh fields come first, in this order, and material uniforms only
// ever go after them.** `check_push_block` requires each one at the offset
// `MeshPush` puts it at, so a uniform inserted anywhere but the end moves `draw`
// and the pipeline refuses the shader — which is the good outcome; the bad one is
// a layout that reflects differently and reads a record out of the middle of a
// float4. The three occupy 24 bytes of the 128 every device must offer, which is
// where `MATERIAL_UNIFORM_BUDGET`'s 104 comes from.
// **The spilled uniform table, when there is one.**
//
// A material's uniforms live in the push block, which leaves 104 bytes — six
// rows of four floats. A material that wants more than that gets this struct
// instead: its *array* columns move here and the block carries a pointer, so the
// ceiling stops being a push-constant limit. `src/shader/material_source.c3` has
// `material_spills` and the budget.
//
// **Empty for almost every material**, and then this line is replaced by nothing
// at all — the generated source for a material that fits is byte for byte what
// it was before the spill existed.
//@table

struct PushData
{
    FrameBlock* frame;
    Instance* instances;
    Draw* draw;
    //@uniforms
};
[vk_push_constant] const PushData push;

// A stream that is absent is absent, not zero-filled: reading through a null
// pointer is a device-lost rather than a fallback, so the flags say which
// streams are really there and the reads are guarded by them.
static const uint FLAG_HAS_NORMALS = 1u;
static const uint FLAG_HAS_UVS     = 2u;
static const uint FLAG_HAS_COLORS  = 4u;
// This bucket is skinned here, in `vertexMain`, before the body sees the vertex.
static const uint FLAG_HAS_SKIN    = 8u;
// This bucket was skinned by the compute pass before the render pass began, so
// the streams are already posed. Mutually exclusive with FLAG_HAS_SKIN.
static const uint FLAG_PRESKINNED  = 16u;

// `Instance.pose` is an offset in matrices with a selector in its top bit: set
// means this frame's live palette, clear means the asset's baked table.
static const uint POSE_LIVE = 0x80000000u;
static const uint POSE_MASK = 0x7fffffffu;

// The four influences of one vertex against one palette, summed into the matrix
// that poses it. Split out so a crossfade can spend it twice — the two frames a
// fade sits between are two offsets into one buffer.
float4x4 blend_joints(float4x4* palette, uint base, uint4 joints, float4 weights)
{
    return weights.x * palette[base + joints.x]
         + weights.y * palette[base + joints.y]
         + weights.z * palette[base + joints.z]
         + weights.w * palette[base + joints.w];
}

// The four influences of one vertex, blended into the matrix that poses it. Byte
// for byte the function `mesh.slang` carries, and for the same reason the record
// is duplicated: this file is that one with the shading lifted out.
//
// A vertex body runs on the *posed* surface — `Vertex.position` is skinned before
// `displace` is called — so a material that ripples a flag ripples the flag the
// skeleton is holding, rather than fighting it.
float4x4 skin_matrix(Draw draw, Instance instance, uint vid)
{
    float4x4* palette = draw.palette;
    if ((instance.pose & POSE_LIVE) != 0) palette = push.frame[0].live_poses;
    uint base = instance.pose & POSE_MASK;

    uint4 joints = draw.joints[vid];
    float4 weights = draw.weights[vid];

    float4x4 pose = blend_joints(palette, base, joints, weights);
    // Uniform across an instance, so this is a scalar branch. **The mix is of
    // joint matrices and not of the transforms behind them** — `mesh.slang` names
    // that lie and argues for it; this file has to make the same trade or a
    // character's shadow fades out of step with the character.
    if (instance.blend <= 0.0) return pose;

    float4x4 from = blend_joints(palette, instance.pose_from & POSE_MASK, joints, weights);
    return pose + (from - pose) * instance.blend;
}

// Always bound, always valid — a 1x1 opaque white image when the material has no
// texture, so an untextured material and a textured one are the same descriptor
// layout and the same pipeline.
[vk::binding(0, 0)] Sampler2D base_color_map;

// The shadow map, reserved exactly as binding 0 is — declared by the template
// rather than by anything a script writes, and carrying the same 1x1 white image
// in a frame with no shadow pass. **This is part of why
// `MATERIAL_BINDING_FIRST` is 3**: a material's own samplers are numbered from
// the first binding the template does not claim, and this file claims three.
[vk::binding(1, 0)] Sampler2D shadow_map;

// **Binding 2 is the environment map, in every shader that shades a surface.**
// The third and last binding a template reserves, which is why
// `MATERIAL_BINDING_FIRST` is 3 and an agent's first sampler is numbered from
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

// The samplers the agent asked for, one line each, at bindings 3..N in the order
// they were declared. **The indices are generated** — `shader/assemble.c3` writes
// them and `shader/reflect.c3` reads them back out of the compiled module, so
// nothing above this file ever spells a binding number and inserting a texture at
// the front of the list cannot silently renumber the ones after it.
//
// They are declared here rather than beside the body so that `fragmentMain` is
// downstream of them too. Nothing generated samples one — an unused sampler is
// exactly what a material that declared a texture and never read it should be —
// and each is bound every draw regardless, with the same 1x1 white image
// `base_color_map` falls back to. A binding the layout declares and the draw
// leaves unwritten is undefined behaviour that no validation layer reports.
//@textures

// **The contract with the agent.** Six values, all of them in world space, in
// texture space, or per instance; none of them a pointer and none of them a
// Vulkan concept. A body that only ever touches `Surface` cannot address the
// wrong buffer, which is most of what `plan.md` §4 means by "removes almost every
// Vulkan failure mode".
struct Surface
{
    float3 albedo;          // base colour factor, times the texture and the instance colour
    float3 normal;          // normalized, world space
    float2 uv;
    float3 position;        // world space
    // This copy's own colour, raw — `albedo` already has it. Here for a body
    // that wants it as something other than a tint: an emissive amount, a
    // per-instance parameter, a selection highlight.
    float4 color;
    // The mesh's own COLOR_0 attribute, interpolated across the triangle, or
    // white where the file carried none. **This is the one that varies across a
    // surface**; `color` above is one value for a whole copy and cannot paint
    // anything.
    //
    // **Not folded into `albedo`, unlike `color`.** glTF says COLOR_0 multiplies
    // the base colour and a body that wants that writes `s.albedo *
    // s.vertex_color.rgb`, which is one line. Doing it here instead would change
    // how every file already loaded renders, and the thing that made this stream
    // exist reads the attribute as a *weight* rather than as a tint — a layer
    // mask, painted per vertex, whose channels are three unrelated numbers and
    // whose product with the albedo is meaningless. So the shader carries the
    // attribute and the body decides what it means.
    float4 vertex_color;
    // How much of the directional light reaches this point: 1 in the open, 0
    // under something, and the values between are the nine PCF taps disagreeing
    // at the edge of a shadow.
    //
    // **A body does not have to read this to be shadowed** — `lambert` already
    // has it folded in, so the default `s.albedo * lambert(s.normal)` lands in
    // the same shadow the built-in shading does. It is here for a body that
    // shades the direct light itself and would otherwise have no way to ask, and
    // for one that wants to use the shadow as something other than light: a
    // wetness mask, a colour shift, moss on the north side.
    //
    // 1 everywhere in a frame with no shadow pass, which is the same value a
    // fully lit surface has — the two are deliberately indistinguishable, because
    // a body that behaved differently "when shadows are off" would be a body that
    // renders differently for a reason it cannot see.
    float shadow;
    // How rough this surface is, 0 to 1. 1 is the default and is a perfectly
    // diffuse surface — the value every material had before there was a term that
    // read one.
    float roughness;
    // How metallic it is, 0 to 1. 0 is the default. A metal has no diffuse: it
    // reflects, and its colour comes back through the highlight instead — see
    // `specular_light`, which also has why a metal here is dark without a sky to
    // reflect.
    float metalness;
    // How strongly a *non*-metal reflects, 0 to 1. **0 is the default, and it is
    // this renderer's own rather than the physical one**: 0.5 is the 4% real
    // dielectrics reflect, and turning that on for everything would have relit
    // every scene already written. `scene/material.c3` has the argument.
    float reflectance;
    // Which row of this material's table this copy selected, **already clamped**
    // to the rows the material declared. So `palette[s.variant]` is always in
    // bounds, whatever a script set, and a material with no table sees zero.
    uint variant;
    // Game clock seconds, `three.clock.time`. The same number `p.time` is, so a
    // paused world stops waving too. Filled by the template; a body does not
    // write it.
    float time;
};

// **The other contract with the agent**, and the one thing about it worth
// reading twice is what it is a picture of: `Vertex` is the *varyings*. The five
// fields at the top are exactly what crosses into the fragment stage, so a body
// that writes one is writing what `Surface` will see — not a request that
// something downstream may or may not honour.
//
// The two at the bottom are inputs and are not read back, which is the only
// asymmetry here and is what keeps the first five honest: `local` is where the
// vertex was before the instance's matrix touched it and there is nowhere to put
// a new one, and `index` names a vertex rather than describing it.
//
// A body is `void displace(inout Vertex v)`, and the default one is empty — so a
// material with no `vertex:` produces a call the compiler folds away and a module
// that is the same shader it was before this existed.
struct Vertex
{
    // Where this copy of this vertex is, **world space**, after the instance's
    // model matrix. Write it to move the vertex; `Surface.position` is whatever
    // this ends up as.
    float3 position;
    // The mesh's normal, rotated into world space. **Not recomputed from
    // anything you do to `position`** — nothing here can know what surface a
    // displaced vertex belongs to. A body that moves a surface far enough for
    // the lighting to notice should write this too; one that ripples a flag by a
    // few centimetres generally should not bother.
    float3 normal;
    // Before `material.repeat` and `material.offset`, which the fragment stage
    // applies on top of whatever this is. So a body that scrolls uv here and a
    // material that tiles compose rather than fight.
    float2 uv;
    // This copy's own colour, in the space `mesh.color` is in — the fragment
    // stage decodes it. Writable, which is how a vertex body tints per copy
    // without a second material.
    float4 color;
    // The mesh's COLOR_0, or white without one. Writable for the same reason the
    // line above is, and worth having here rather than only in `shade` because a
    // displacement driven by a painted weight — grass height, a wind mask — is a
    // vertex-stage question and this is the only per-vertex value in the struct
    // that an artist can author.
    float4 vertex_color;
    // Already clamped to the rows the material declared, so `palette[v.variant]`
    // is in bounds here for the same reason it is in `shade`.
    uint variant;

    // ---- inputs, not read back ----

    // Object space, exactly as the mesh stores it: the position before the
    // instance's model matrix. This is what a displacement wants to be a function
    // of when the effect should scale with the mesh — a wave along a plane's own
    // length rather than along the world's X axis.
    float3 local;
    // `SV_VertexID`. A per-vertex seed, which is what a hash-driven jitter or a
    // scatter needs and nothing else in here provides.
    uint index;
    // Game clock seconds. An input, like `local` and `index` — a body that
    // writes it does not change `Surface.time`.
    float time;
};

struct VertexOutput
{
    float3 normal : NORMAL;
    float2 uv : TEXCOORD0;
    // `mesh.slang` carries no world position because nothing it computes needs
    // one, and a shading body cannot recover it from the others. Anything
    // positional — a distance falloff, a world-space gradient, a clip plane —
    // starts here.
    //
    // TEXCOORD1 rather than POSITION: POSITION is the vertex *input* semantic,
    // and spelling an interpolated output that way invites the reader to confuse
    // it with `sv_position`, which is in clip space and is not this.
    float3 world : TEXCOORD1;
    // COLOR0 and TEXCOORD2 are `mesh.slang`'s too, in the same order: the two
    // shaders read one `Instance` array written by one `build_draw_list`, and
    // the varyings that carry it across the stages are as much a shared format
    // as the struct is.
    float4 color : COLOR0;
    nointerpolation uint variant : TEXCOORD2;
    // COLOR1, and **`mesh.slang` has no counterpart** — it is the third varying
    // this shader carries and that one does not, after `world` and `variant`. A
    // colour attribute changes no pixel without a body to read it, so paying for
    // the interpolation in the shader that has no body would be paying for
    // nothing on every draw in the frame.
    float4 vertex_color : COLOR1;
    float4 sv_position : SV_Position;
};

// How many rows the material's uniform arrays have, or 1 when it declared none.
// Generated, because `s.variant` is clamped against it and a table is the only
// thing that gives a variant meaning.
//@rows

// The sRGB decode. `mesh.slang` carries the same function and the whole argument
// for it; this copy exists for the same reason `lambert` below is a copy, which
// is that a material is a change of *shading* and not a second renderer. If the
// two ever disagree, a `ShaderMaterial` whose body is the default
// `s.albedo * lambert(s.normal)` stops matching no material at all.
float3 srgb_to_linear(float3 c)
{
    float3 lo = c / 12.92;
    float3 hi = pow(max(c + 0.055, 0.0) / 1.055, 2.4);
    return lerp(hi, lo, step(c, 0.04045));
}

// How much of the light reaches this point: 1 fully lit, 0 fully shadowed.
//
// **Character for character what `mesh.slang` carries**, and the duplication is
// the same duplication `srgb_to_linear` and `lambert` are: a material is a change
// of shading and not a second renderer, so a body whose text is the default has
// to land in the same shadow no material at all lands in. `mesh.slang` holds the
// long account of the four early exits and the two biases; this copy is the
// function and not the argument.
float shadow_factor(float3 position, float3 normal)
{
#ifdef THREE_BAKE
    // Nothing is occluded in a bake, which is also what lets the bake pipeline
    // leave binding 1 unbound: with the sampler unread, Slang drops it from the
    // layout and `pipeline_declares_binding` answers no.
    return 1.0;
#else
    float4 params = push.frame[0].shadow;
    if (params.w <= 0.0) return 1.0;

    float3 offset = position + normalize(normal) * params.z;
    float4 clip = mul(push.frame[0].light_view_projection, float4(offset, 1.0));
    float3 ndc = clip.xyz / clip.w;
    if (ndc.z < 0.0 || ndc.z > 1.0) return 1.0;

    float2 uv = float2(0.5 + 0.5 * ndc.x, 0.5 - 0.5 * ndc.y);
    if (uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0) return 1.0;

    float reference = ndc.z - params.y;
    float lit = 0.0;
    for (int y = -1; y <= 1; y++)
    {
        for (int x = -1; x <= 1; x++)
        {
            float depth = shadow_map.SampleLevel(uv + float2(x, y) * params.x, 0.0).r;
            lit += reference <= depth ? 1.0 : 0.0;
        }
    }

    return 1.0 - params.w * (1.0 - lit / 9.0);
#endif
}

// This fragment's shadow, looked up **once** and left where `lambert` can reach
// it.
//
// ## Why this is a global and not a parameter
//
// `lambert(s.normal)` is written that way in every material in this project, in
// `getApiDocs`, in `examples/vfx.js` and in the body `shader.js` generates when a
// script gives a `vertex:` and no `fragment:`. Shadows had to reach all of them
// or a `ShaderMaterial` would silently be the one thing in the scene that stands
// in its own light — so the choices were to change that signature everywhere, or
// to put the one value it is missing somewhere the function can find it.
//
// The signature change was the tempting one and it is worse. `lambert(s)` would
// leave `lambert(s.normal)` compiling and unshadowed, which is a body that keeps
// working and quietly stops matching the default look — exactly the class of
// silent divergence this file's header says the duplication exists to prevent.
//
// **A `static` global in Slang is per invocation**, not shared across fragments,
// so this is a local with a wider scope and not state. It is written in exactly
// one place — `fragmentMain`, immediately before `shade` runs — and read in
// exactly one, `lambert`.
//
// It is 1.0 in the vertex stage and stays 1.0 there: `shadow_factor` needs a
// world position and a normal that the fragment stage has and `displace` does
// not, and a vertex body calling `lambert` is asking about the light and not
// about the shadow. That is documented rather than fixed, because moving the
// lookup into the vertex stage would shadow a surface per vertex, which on a
// ground plane of two triangles is no shadow at all.

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
    answer = float3(0.0);
#ifdef THREE_BAKE
    // A bake is not a frame and must not follow `three.debug.view`: an export run
    // while somebody was looking at the shadow factor would write the shadow
    // factor into the file.
    return false;
#else
    float mode = push.frame[0].debug.x;
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

    answer = float3(shadow_map.SampleLevel(uv, 0.0).r);
    return true;
#endif
}

static float g_shadow = 1.0;

// The direct light reaching this point, as a colour, so a body can ask for the
// built-in diffuse without reproducing it. `return s.albedo * lambert(s.normal);`
// is the same arithmetic `mesh.slang` performs for a mesh with no material at all
// — which is the property that makes a material a change of *shading* rather than
// a second renderer, and the reason this function is duplicated there character
// for character.
//
// **A colour rather than a factor**, since `three.lights` gave every light one.
// `s.albedo * lambert(s.normal)` did not change meaning by it — a float3 times a
// float3 is the per-channel product it always was — and the one body that stops
// compiling is one that assigned the answer to a `float`.
//
// **Every light, not just the sun.** The loop runs `three.lights.length` times,
// and light zero is the only one the shadow applies to because it is the only one
// the map was fitted around.
//
// **The shadow is in here**, folded into the direct term and not into the ambient
// floor, exactly as `mesh.slang` folds it. A body that wants the two apart has
// `s.shadow`.
//
// **This is the diffuse half and nothing else.** `specular(s)` is the other half
// and `standard(s)` is both — a body written against `lambert` alone is a matte
// surface, which is what every body written before the specular term existed
// asked for and still gets.
float3 lambert(float3 normal)
{
#ifdef THREE_BAKE
    // The identity, so `s.albedo * lambert(s.normal)` — the body most materials
    // here are — bakes the albedo and nothing else.
    return float3(1.0, 1.0, 1.0);
#else
    float ambient = push.frame[0].lighting.x;
    uint count = (uint)push.frame[0].lighting.y;
    float3 direct = float3(0.0, 0.0, 0.0);
    for (uint i = 0u; i < count; i++)
    {
        Light light = push.frame[0].lights[i];
        float n_dot_l = max(dot(normal, normalize(light.direction.xyz)), 0.0);
        if (i == 0u) n_dot_l *= g_shadow;
        direct += light.color.rgb * light.color.w * n_dot_l;
    }
    return ambient + (1.0 - ambient) * direct;
#endif
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
#ifdef THREE_BAKE
    // A highlight is a fact about where the camera is, and a baked texture is
    // looked at from everywhere. It is also the term that would put the sun into
    // the base colour as a white blob that never moves.
    return float3(0.0, 0.0, 0.0);
#else
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
        float3 to_light = normalize(light.direction.xyz);
        float n_dot_l = max(dot(normal, to_light), 0.0);
        if (n_dot_l <= 0.0) continue;

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
        float occlusion = i == 0u ? g_shadow : 1.0;
        sum += light.color.rgb * light.color.w * occlusion
             * distribution * geometry * fresnel / (4.0 * n_dot_v);
    }
    return sum;
#endif
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
#ifdef THREE_BAKE
    // A reflection is a fact about where the camera is, exactly as a highlight
    // is, and a baked texture is looked at from everywhere.
    return float3(0.0, 0.0, 0.0);
#else
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
#endif
}


// This surface's highlight, so a body can have one without reproducing the four
// terms above. `s.roughness`, `s.metalness` and `s.reflectance` are what it
// reads, and a material nobody set them on answers zero.
float3 specular(Surface s)
{
    return specular_light(s.normal, s.position, s.albedo, s.roughness, s.metalness, s.reflectance);
}

// The built-in shading with a colour and a normal the body worked out for
// itself — which is what a body that blends layers or reads a normal map has.
//
// The overload below is this one with the surface's own two, and is what a body
// that changed neither wants.
float3 standard(Surface s, float3 albedo, float3 normal)
{
#ifdef THREE_BAKE
    // The colour and not the colour times `1 - metalness`. With `lambert` at 1 and
    // the highlight at 0 the expression below would already be unlit, and it would
    // bake a metal as black — a surface whose colour comes back entirely through a
    // reflection the file has no environment for.
    return albedo;
#else
    return albedo * lambert(normal) * (1.0 - s.metalness)
         + specular_light(normal, s.position, albedo, s.roughness, s.metalness, s.reflectance)
         + environment_light(normal, s.position, albedo, s.roughness, s.metalness, s.reflectance);
#endif
}

// The built-in shading, whole: exactly what a mesh with no ShaderMaterial draws.
//
// `return standard(s);` is the body to start from when the material is meant to
// look like the default and differ somewhere; `s.albedo * lambert(s.normal)` is
// the body to start from when it is meant to be matte, which is what every body
// written before the specular term existed asked for and still gets.
float3 standard(Surface s)
{
    return standard(s, s.albedo, s.normal);
}

// A tangent-space normal map applied to a surface that carries no tangents.
//
// **The meshes here have positions, normals and uvs and nothing else.** There is
// no `TANGENT` stream, `mesh.slang` has nowhere to put one, and a generated
// primitive never had one to lose — so the frame is rebuilt per pixel from the
// screen-space derivatives of the world position and the uv. That is the
// standard cotangent-frame construction; it costs four derivatives and two cross
// products, and what it buys is that a normal map works on *any* textured mesh
// here rather than only on the ones whose exporter wrote tangents.
//
// `texel` is the map's rgb exactly as sampled. The decode from [0,1] to a
// direction happens in here, which is the half worth reading twice: **the map
// has to be loaded `LinearSRGBColorSpace`**. Through an sRGB view the stored
// 0.5 that means "no tilt" arrives as 0.21, so every surface leans the same way
// and the detail goes soft — it reads as a bad bake and the file is fine.
//
//     const bumps = three.texture('brick_n.png', { colorSpace: three.LinearSRGBColorSpace });
//     // ... in the material's fragment body:
//     float3 n = mapped_normal(s, brick_normal.Sample(s.uv).rgb);
//     return s.albedo * lambert(n);
//
// Two things it cannot do, both inherited from having no baked tangents:
// mirrored uv islands come out mirrored rather than flipped, because a
// derivative cannot see the seam a tangent would have recorded; and a face with
// degenerate uvs has no frame at all, which is the interpolated normal returned
// unchanged rather than a NaN.
//
// **Fragment stage only.** `ddx`/`ddy` do not exist in a vertex shader, so
// calling this from a `vertex:` body is a compile error rather than a wrong
// picture — which is the good outcome, and the reason it takes a `Surface`.
float3 mapped_normal(Surface s, float3 texel)
{
    float3 n = normalize(s.normal);

    float3 dp_dx = ddx(s.position);
    float3 dp_dy = ddy(s.position);
    float2 duv_dx = ddx(s.uv);
    float2 duv_dy = ddy(s.uv);

    // The tangent and bitangent that carry those uv derivatives, solved in the
    // plane perpendicular to the interpolated normal — so the frame agrees with
    // the normal the mesh already has rather than replacing it.
    float3 dp_dy_perp = cross(dp_dy, n);
    float3 dp_dx_perp = cross(n, dp_dx);
    float3 tangent = dp_dy_perp * duv_dx.x + dp_dx_perp * duv_dy.x;
    float3 bitangent = dp_dy_perp * duv_dx.y + dp_dx_perp * duv_dy.y;

    float longest = max(dot(tangent, tangent), dot(bitangent, bitangent));
    // No uv gradient, so there is no frame to build and nothing sensible to
    // return but the normal that was already there. `rsqrt(0)` is an infinity
    // and the pixel after it is a NaN, which the rasteriser is entitled to draw
    // as anything at all.
    if (longest <= 0.0) return n;

    // One scale for both axes rather than normalizing each: the two are the same
    // skew seen along two directions, and scaling them apart squares it.
    float scale = rsqrt(longest);
    float3 direction = texel * 2.0 - 1.0;
    return normalize(
        tangent * (direction.x * scale)
        + bitangent * (direction.y * scale)
        + n * direction.z
    );
}

// The base colour, sampled somewhere other than where the template sampled it.
//
// `s.albedo` is `base_color` times this copy's colour times `base_color_map` at
// `s.uv`, assembled in `fragmentMain` before the body runs. A body that *moves*
// the uv — parallax is the one that does — needs that same product at the uv it
// moved to, and cannot scale its way there from `s.albedo`: the texel that went
// into the product is not recoverable from it.
//
// So this is `fragmentMain`'s own two lines again, with a uv of the caller's
// choosing. It reads the push block, which is why it lives here rather than in
// generated source — a body sees `Surface` and nothing else.
float3 base_albedo(Surface s, float2 uv)
{
    Draw draw = push.draw[0];
    float3 albedo = draw.base_color.rgb * s.color.rgb;
    if ((draw.flags & FLAG_HAS_UVS) != 0) albedo *= base_color_map.Sample(uv).rgb;
    return albedo;
}

// Where to sample a surface with a height map on it, so that its relief reads as
// relief instead of as a picture of one.
//
// Parallax mapping: the ray the camera actually sent hit the *displaced* surface
// before it reached the flat one the mesh has, so the texel belonging to this
// pixel is not the one under it. One step, no march — which is the version that
// costs a handful of instructions and shifts a texture convincingly, and is not
// the version that occludes or self-shadows.
//
// **`depth` is in metres, and that is what the derivatives buy.** The screen-space
// steps of the world position and of the uv are the same two steps measured two
// ways, so dividing one by the other leaves how far a unit of u and a unit of v
// reach across this surface — a property of the mesh and its uvs, with the screen
// cancelled out. A `bump.distance` of 0.1 therefore means a tenth of a metre of
// relief on a surface tiled once and a tenth of a metre on the same surface tiled
// fifty times, rather than meaning two different things.
//
// `height` is the map's red channel as sampled, and **0.5 is the plane the mesh
// already has**: half the map stands out of it and half sinks in, so a stack that
// turns parallax on does not slide as a whole.
//
// Two things it declines to do, both for the same reason a highlight does:
//
//  - **Nothing in a bake.** Where the texture slides to is a fact about where the
//    camera is, and a baked image is looked at from everywhere.
//  - **Nothing without a uv gradient.** A degenerate uv has no frame to solve, so
//    the uv comes back as it went in rather than as an infinity — which the
//    rasteriser would be entitled to draw as anything at all.
//
// **Fragment stage only**, exactly like `mapped_normal`, and a compile error in a
// `vertex:` body rather than a wrong picture.
float2 parallax_uv(Surface s, float2 uv, float height, float depth)
{
#ifdef THREE_BAKE
    return uv;
#else
    if (depth == 0.0) return uv;

    float3 n = normalize(s.normal);
    float3 view = normalize(push.frame[0].camera.xyz - s.position);

    float3 dp_dx = ddx(s.position);
    float3 dp_dy = ddy(s.position);
    float2 duv_dx = ddx(uv);
    float2 duv_dy = ddy(uv);

    float det = duv_dx.x * duv_dy.y - duv_dy.x * duv_dx.y;
    if (abs(det) < 1e-12) return uv;

    // The world directions one unit of u and one unit of v run along, by solving
    // the two screen steps against each other.
    float3 du = (dp_dx * duv_dy.y - dp_dy * duv_dx.y) / det;
    float3 dv = (dp_dy * duv_dx.x - dp_dx * duv_dy.x) / det;
    float du2 = dot(du, du);
    float dv2 = dot(dv, dv);
    if (du2 <= 0.0 || dv2 <= 0.0) return uv;

    // The view flattened into the surface. Its length is the sine of the angle to
    // the normal, which is the offset limiting everybody uses: head-on it is zero
    // and nothing moves, and at a grazing angle it is one rather than the
    // infinity a divide by `dot(view, n)` would give — and that infinity is the
    // texture sliding off the model at the silhouette.
    float3 along = view - n * dot(view, n);
    float lift = (height - 0.5) * depth;

    return uv + lift * float2(dot(along, du) / du2, dot(along, dv) / dv2);
#endif
}

// The agent's vertex body, bracketed by `#line` exactly as the fragment one is
// and preceded by its own copy of the uniform `#define`s — which are `#undef`ed
// again immediately after it. **Two scoped copies rather than one block covering
// both stages**, because `vertexMain` sits between them and a uniform named
// `position`, `normal`, `world` or `output` would otherwise rewrite its locals
// into push fields. That is `material_source.c3`'s argument for `#undef`, one
// stage further along.
//
// Placed here rather than beside `Vertex` so that a vertex body sees everything a
// fragment body does — `MATERIAL_ROWS`, `lambert`, `srgb_to_linear` and the
// samplers are all above this line. The two bodies differ in what they are handed
// and in nothing else they can reach.
//
// When the material declared no vertex body this is `void displace(inout Vertex
// v) { }` and nothing else: an empty function the compiler folds into the call
// below, so a material without one compiles to the module it always did.
//@vdefines
//@vertex

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

    // Before `local` is taken, so a body's `Vertex.local` is the vertex this copy
    // actually wears rather than the neutral face nobody is looking at.
    apply_morph(draw, instance, vid, position, normal);

    // The bind pose, kept before either skinning path runs: this is what
    // `Vertex.local` hands a body, and it has to be the pose the mesh was authored
    // in or a displacement sized by the mesh's own length slides across the
    // surface every time the character moves.
    float3 local = position;

    // Before the model matrix, and before `displace`: a joint matrix is in the
    // character's own space, and a body that moves a vertex is moving one the
    // skeleton has already placed.
    if ((draw.flags & FLAG_HAS_SKIN) != 0)
    {
        float4x4 pose = skin_matrix(draw, instance, vid);
        position = mul(pose, float4(position, 1.0)).xyz;
        normal = mul((float3x3)pose, normal);
    }
    else if ((draw.flags & FLAG_PRESKINNED) != 0)
    {
        SkinnedVertex skinned = draw.posed[iid * draw.skin_stride + vid];
        position = skinned.position;
        normal = skinned.normal;
    }

    float4 world = mul(instance.model, float4(position, 1.0));

    // Everything the fragment stage is going to receive, gathered into one struct
    // *before* the agent's body runs and read back out of it afterwards. The
    // gather is what makes `Vertex` a picture of the varyings rather than a
    // parallel set of values that has to be kept in step with them.
    Vertex v;
    v.position = world.xyz;
    v.normal = mul((float3x3)instance.normal, normal);
    v.uv = float2(0.0, 0.0);
    if ((draw.flags & FLAG_HAS_UVS) != 0) v.uv = draw.uvs[vid];
    v.color = instance.color;
    // White is the identity for every use a body has for this, so a mesh without
    // the attribute and a mesh painted white are the same surface — which is what
    // makes `s.vertex_color` safe to multiply by unconditionally.
    v.vertex_color = float4(1.0, 1.0, 1.0, 1.0);
    if ((draw.flags & FLAG_HAS_COLORS) != 0) v.vertex_color = draw.colors[vid];
    // Clamped **here**, before the body sees it, so that `palette[v.variant]` in
    // a vertex body is in bounds for the same reason it is in a fragment one.
    // `fragmentMain` clamps again rather than trusting this, because a body may
    // write the field.
    v.variant = min(instance.variant, MATERIAL_ROWS - 1u);
    v.local = local;
    v.index = vid;
    v.time = push.frame[0].lighting.z;

#ifdef THREE_BAKE
    // **The mesh's own TEXCOORD_0, kept before `displace` can rewrite it.**
    //
    // The two uvs are not the same question. What the body *samples* with is
    // whatever it ends up as — a vertex body computing `v.uv` from `v.local` is
    // the ordinary case — but where the answer is *stored* has to be the layout
    // the exported file carries, which is the attribute as the mesh holds it.
    // Rasterising into the computed one instead writes a picture the file then
    // indexes with different coordinates: a correct bake, sampled wrong, which
    // reads as the mesh having lost its texture rather than as a mix-up here.
    float2 bake_uv = v.uv;
#endif

    displace(v);

    output.world = v.position;
#ifdef THREE_BAKE
    // The bake rasterises in **uv space**: the triangle is placed by where it lands
    // in the texture, and everything else — the world position, the normal, the uv
    // the body will sample with — crosses into the fragment stage exactly as it
    // would in a frame. So a body reading `s.position` gets the position this copy
    // really has, and one reading `s.uv` gets the uv its own vertex body computed.
    //
    // `displace` still runs first, and `bake_uv` above is why that is safe.
    //
    // The viewport is set *unflipped* for this — `MaterialBaker` does it — because
    // uv (0,0) is the top-left texel of an image and every other pass in the
    // project flips Y to put world space the right way up.
    output.sv_position = float4(bake_uv * 2.0 - 1.0, 0.0, 1.0);
#else
    // Built from the displaced position, which is the whole point: a vertex that
    // moved and a clip position that did not would be geometry lit and textured
    // as though it were somewhere it is not drawn.
    output.sv_position = mul(push.frame[0].view_projection, float4(v.position, 1.0));
#endif
    output.normal = v.normal;
    output.uv = v.uv;
    output.color = v.color;
    output.variant = v.variant;
    output.vertex_color = v.vertex_color;

    return output;
}

// The uniforms arrive as bare names. A `#define` rather than a global or a
// `let`, so that `tint` in the body *is* `push.tint` textually and an agent has
// no reason to learn that a push block exists — which is what makes `plan.md`
// §4's one-line example work exactly as it is written there.
//
// They are emitted here rather than beside the push block, and undefined again
// straight after the body, so the substitution reaches the agent's lines and
// nothing else. That is not tidiness: a uniform named `a` would otherwise turn
// `push.base_color.a` in `fragmentMain` into nonsense, and the reserved-name
// list cannot plausibly cover every swizzle.
//@defines
//@shade

[shader("fragment")]
float4 fragmentMain(VertexOutput input) : SV_Target
{
    Draw draw = push.draw[0];

    Surface s;
    // The instance colour is folded into albedo here, exactly as `mesh.slang`
    // folds it: a body that writes `return s.albedo * lambert(s.normal)` — the
    // default look — respects `mesh.color` without knowing it exists, and a body
    // that wants the raw value has `s.color`.
    // **The transform is applied to the sample and to `s.uv` alike.** A body that
    // samples its own texture with `s.uv` has to land on the same texel the
    // default shading does, or `material.repeat` would mean one thing without a
    // custom body and nothing at all with one.
    float2 uv = input.uv * draw.uv_transform.xy + draw.uv_transform.zw;
    s.albedo = draw.base_color.rgb * srgb_to_linear(input.color.rgb);
    if ((draw.flags & FLAG_HAS_UVS) != 0)
    {
        s.albedo *= base_color_map.Sample(uv).rgb;
    }
    s.normal = normalize(input.normal);
    s.uv = uv;
    s.position = input.world;
    s.color = float4(srgb_to_linear(input.color.rgb), input.color.a);
    // No decode, unlike `color` above. glTF defines COLOR_0 linear — it is the
    // same rule `base_color` follows and for the same reason: this came out of a
    // file rather than out of a colour picker in a script.
    s.vertex_color = input.vertex_color;
    // Clamped once, here, rather than at each use: an out-of-range index into a
    // push-constant array is undefined behaviour that reads whatever is next in
    // the block — a wrong colour with no error anywhere, which is precisely the
    // class of failure this project spends its comments on.
    s.variant = min(input.variant, MATERIAL_ROWS - 1u);
    // Once, here, and then left in two places: on the surface for a body that
    // wants it by name, and in `g_shadow` for `lambert` to fold into the direct
    // term. Nine texture taps, so once is the number that matters — a body
    // calling `lambert` three times pays for the lookup no more than a body that
    // never calls it at all.
    s.shadow = shadow_factor(s.position, s.normal);
    g_shadow = s.shadow;
    // Straight off the record, unclamped: `setSurface` clamps at the boundary, so
    // a second clamp here would be a second place for the range to be decided.
    s.roughness = draw.surface.x;
    s.metalness = draw.surface.y;
    s.reflectance = draw.surface.z;
    s.time = push.frame[0].lighting.z;

    // Before `shade`, so a debug view of a scene whose bodies are expensive is
    // still one render — and so a body that cannot compile is still diagnosable.
    float3 view;
    if (debug_view(s.position, s.normal, view)) return float4(view, 1.0);

    // **Alpha is still not the agent's to return**, and blending did not change
    // that. `shade` answers with linear rgb; the alpha is the material's own
    // opacity times this copy's `mesh.color.a`, which is to say it is decided by
    // whoever built the material and whoever placed the instance — never by the
    // body. A *body* therefore cannot make geometry invisible by accident, which
    // is the failure that looks like nothing rendered rather than like a shader
    // bug, and so is the one an agent spends its budget on the wrong file for. A
    // *script* can, deliberately, by asking for it in the two places that say so.
    //
    // It also does nothing unless the material was built transparent: an opaque
    // pipeline writes no alpha. See `BlendMode`.
    return float4(shade(s), draw.base_color.a * input.color.a);
}
