// three.c3 shadow pass — depth only, from the light's point of view.
//
// **Compiled at runtime from this file**, like `mesh.slang`, `material.slang`
// and `skin.slang`, through the same `src/shader/compile.c3`. Two things make it
// unlike the other three:
//
//  - **It has one entry point and no fragment stage.** A depth-only pipeline
//    needs no fragment shader at all — there is nothing to write but the depth
//    the rasteriser produces — so `SHADOW_ENTRIES` names `vertexMain` alone and
//    `MeshPipeline.init_shadow` builds a pipeline with one stage and no colour
//    attachment. A fragment stage here would be a stage that returns nothing on
//    every pixel of every caster in the scene.
//  - **It declares no samplers** — in the compile every ordinary caster uses. A
//    second compile of this same file, with `THREE_SHADOW_CUTOUT` defined,
//    declares the base colour map and a fragment stage that discards below
//    `material.alphaTest`, so a leaf card casts the shadow of the leaf. Two
//    compiles rather than one sampler on the pipeline every caster shares: a
//    scene with no cut-outs in it then pays neither the binding nor the tap.
//    `ShadowMap.build_cutout_pipeline` is the second compile and builds it only
//    once something in the scene has asked.
//
// ## Why the whole geometry contract is repeated here
//
// The same reason `material.slang` repeats it: the push block, the record behind
// it and the instance array are a **wire format** shared with `gpu/pipeline.c3`
// and `render/pass.c3`, and a pass that laid any of them out differently would
// read geometry from the wrong address while still compiling and still drawing
// something. `every_shader_declares_the_same_contract` compares this text
// against the other two rather than trusting the comment.
//
// The corollary is the part worth knowing before editing: **this shader must pose
// a vertex exactly the way `mesh.slang` poses it**, or a character's shadow is
// the shadow of a different pose. Both skinning paths are here for that reason,
// including the compute one — which is where `plan.md` §3's "a shadow map plus
// the main pass is roughly break-even" stops being a prediction: a compute-skinned
// character blends once for two passes, and a vertex-skinned one blends twice.

// Byte for byte what `mesh.slang`, `material.slang` and `scene/scene.c3` declare.
struct Instance
{
    float4x4 model;
    float4x4 normal;
    float4 color;
    uint variant;
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

// Byte for byte what `mesh.slang`, `material.slang` and `gpu/pipeline.c3`
// declare. Nothing here reads a light — this pass is fitted around light zero and
// the fit arrives as `light_view_projection` — and the struct is here because the
// offsets are the contract, not because the fields are used.
struct Light
{
    float4 direction;
    float4 color;
};

// Byte for byte what `mesh.slang` and `gpu/pipeline.c3` declare. This pass reads
// `light_view_projection` and `live_poses` and nothing else in it — the fields
// are here because the offsets are the contract, not because they are all used.
struct FrameBlock
{
    float4x4 view_projection;
    float4 lighting;
    float4x4* live_poses;
    float4x4 light_view_projection;
    float4 shadow;
    float4 debug;
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

// Byte for byte what `mesh.slang` and `shaders/skin.slang` declare.
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

// Byte for byte what `mesh.slang` and `gpu/pipeline.c3`'s `DrawRecord` declare.
struct Draw
{
    float3* positions;
    float3* normals;
    float2* uvs;
    float4* colors;
    uint4* joints;
    float4* weights;
    float4x4* palette;
    SkinnedVertex* posed;
    // This mesh's morph targets: `morph_targets` blocks of `vertex_count`
    // displacements each, target-major, so one target's block is contiguous and
    // the loop below walks it with one stride. Null on every mesh without them,
    // which is nearly all of them.
    MorphDelta* morph;
    float4 base_color;
    uint flags;
    uint skin_stride;
    // How many of `morph`'s blocks to apply, and how many weights this bucket's
    // instances read. **Zero is the whole test** — a mesh with no targets, a soft
    // bucket, or a frame with no weight buffer all arrive here as zero and the
    // loop does not run.
    uint morph_targets;
    float4 uv_transform;
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
};

// The mesh contract exactly, and nothing appended: there are no material
// uniforms in a depth pass — the cut-out threshold rides `Draw.surface.w`, which
// the record already carried — so `MESH_PUSH_FIELDS` is not merely satisfied
// here, it is the whole block. 24 bytes of the 128 every device offers.
struct PushData
{
    FrameBlock* frame;
    Instance* instances;
    Draw* draw;
};
[vk_push_constant] const PushData push;

static const uint FLAG_HAS_NORMALS = 1u;
static const uint FLAG_HAS_UVS     = 2u;
static const uint FLAG_HAS_COLORS  = 4u;
static const uint FLAG_HAS_SKIN    = 8u;
static const uint FLAG_PRESKINNED  = 16u;

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

// The four influences of one vertex, blended into the matrix that poses it. The
// same function `mesh.slang` carries, and it has to be: a shadow cast from a
// different blend is a character whose shadow walks out of step with it.
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

// **No normal, no colour — and no `displace`.**
//
// The first two are absences that cost nothing: depth is a function of position,
// so a varying nothing reads is interpolation nobody pays for. A uv used to be on
// that list and is now the one thing the cut-out variant adds, which is exactly
// how much it is worth carrying it for.
//
// The third is a real limitation and is stated rather than hidden: a
// `ShaderMaterial` with a `vertex:` body moves its surface in `material.slang`
// and this pass does not run that body, so such a mesh casts the shadow of its
// *undisplaced* geometry. `render/shadow.c3` carries what it would take to fix —
// the body would have to be assembled into this template too, which makes a
// shadow pipeline per material where today there are two.
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

// Where one vertex of one copy lands in the light's clip space.
//
// Split out of `vertexMain` because there are two of those: the depth-only
// entry point and the cut-out one, which needs a uv beside the position. Both
// have to pose a vertex *identically* — a leaf whose shadow is cast from a
// different pose is the same bug as a character whose is.
float4 posed_clip(uint vid, uint iid)
{
    Draw draw = push.draw[0];
    Instance instance = push.instances[iid];

    float3 position = draw.positions[vid];

    // A shadow has to be cast by the face the character is wearing, so the same
    // displacement runs here. `normal` is a discard — this pass has none, and the
    // shared function writes one.
    float3 unused_normal = float3(0.0, 1.0, 0.0);
    apply_morph(draw, instance, vid, position, unused_normal);

    // The two skinning paths, in the same order and with the same exclusivity
    // `mesh.slang` states: `render/pass.c3` sets one flag or the other, never
    // both. An `if` rather than a ternary, because one of the two pointers is
    // null on any given draw.
    if ((draw.flags & FLAG_HAS_SKIN) != 0)
    {
        position = mul(skin_matrix(draw, instance, vid), float4(position, 1.0)).xyz;
    }
    else if ((draw.flags & FLAG_PRESKINNED) != 0)
    {
        position = draw.posed[iid * draw.skin_stride + vid].position;
    }

    // Model first, light second — the same order the main pass uses with the
    // camera, and the only order that makes sense: a joint matrix is in the
    // character's space, the model matrix puts the character in the world, and
    // the light looks at the world.
    return mul(push.frame[0].light_view_projection, mul(instance.model, float4(position, 1.0)));
}

#ifdef THREE_SHADOW_CUTOUT

// ## The cut-out variant
//
// Everything from here down exists only in the second compile of this file —
// `ShadowMap.build_cutout_pipeline` prepends the define, which is `THREE_BAKE`'s
// arrangement one file along. **The plain pass must not merely skip this code but
// not contain it**: reflection reports the linked program, so a sampler declared
// here would put a descriptor binding on the pipeline every ordinary caster
// shares, and a binding declared and never written is undefined behaviour rather
// than a wasted byte.
//
// What it buys is the thing the header above says this pass could not do: a leaf
// card casts the shadow of the leaf instead of the shadow of its quad. What it
// costs is one pipeline object, a bind per bucket of cut-out casters, and a
// texture tap per fragment of them — charged only to the materials that set
// `alphaTest`, and to nothing else in the scene.

// The material's base colour map, and the only sampler this pass ever declares.
// Binding 0, which is `mesh.slang`'s number for the same image and is written by
// hand in `MeshPass.record_casters` for `render/bind.c3`'s reason: only the pass
// knows what this image is.
[vk::binding(0, 0)] Sampler2D base_color_map;

// Byte for byte what `surface.slang` declares, and a copy for the reason every
// other declaration in this file is one: this shader is compiled on its own and
// shares no text with the templates. A copy that drifts is a cut-out sampled
// from a different part of the sheet than the surface was drawn from, which is a
// leaf whose shadow is a different leaf.
float2 variant_uv(float2 uv, float4 row)
{
    uint turns = ((uint)row.z) & 3u;
    if (turns == 1u) uv = float2(uv.y, 1.0 - uv.x);
    else if (turns == 2u) uv = float2(1.0 - uv.x, 1.0 - uv.y);
    else if (turns == 3u) uv = float2(1.0 - uv.y, uv.x);

    uint flip = (uint)row.w;
    if ((flip & 1u) != 0u) uv.x = 1.0 - uv.x;
    if ((flip & 2u) != 0u) uv.y = 1.0 - uv.y;

    return uv + row.xy;
}

// One varying, and it is the whole difference between the two pipelines: a
// fragment stage that discards needs somewhere to sample, and depth needs
// nothing at all.
struct VertexOutput
{
    float4 position : SV_Position;
    float2 uv : TEXCOORD0;
};

[shader("vertex")]
VertexOutput vertexMain(uint vid : SV_VertexID, uint iid : SV_InstanceID)
{
    Draw draw = push.draw[0];

    VertexOutput output;
    output.position = posed_clip(vid, iid);

    // `mesh.slang`'s vertex stage exactly: the mesh's own uv, then this copy's
    // row of the variant table. The `uv_transform` is deliberately *not* here and
    // is applied in the fragment stage, which is where `mesh.slang` applies it —
    // the two have to sample the same texel or the cut-out and the surface
    // disagree about where the leaf is.
    output.uv = float2(0.0, 0.0);
    if ((draw.flags & FLAG_HAS_UVS) != 0) output.uv = draw.uvs[vid];
    if (draw.uv_variant_count != 0u)
    {
        Instance instance = push.instances[iid];
        output.uv = variant_uv(output.uv, draw.uv_variants[min(instance.variant, draw.uv_variant_count - 1u)]);
    }
    return output;
}

// The one thing a shadow fragment stage is for: deciding this texel is not
// there. It writes nothing — depth is still the rasteriser's — so `void` is the
// whole return type and a `discard` is the whole body.
[shader("fragment")]
void fragmentMain(VertexOutput input)
{
    Draw draw = push.draw[0];
    // A mesh with no uvs has nowhere to put a map, so there is nothing to cut and
    // the whole quad casts — which is what this pass did for everything before
    // the variant existed.
    if ((draw.flags & FLAG_HAS_UVS) == 0) return;

    float2 uv = input.uv * draw.uv_transform.xy + draw.uv_transform.zw;
    // A plain `Sample` and not `stochastic_sample`, even on a material that asked
    // for scattering. The three-tap blend is there to hide a tiling repeat in a
    // *colour*, and a blend of three alphas cuts a shape that is in none of the
    // three. `plan.md` §27 is where the two features meet, and this is the side
    // of it that has an answer.
    if (base_color_map.Sample(uv).a * draw.base_color.a < draw.surface.w) discard;
}

#else

[shader("vertex")]
float4 vertexMain(uint vid : SV_VertexID, uint iid : SV_InstanceID) : SV_Position
{
    return posed_clip(vid, iid);
}

#endif
