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
//  - **It declares no samplers.** Alpha-tested shadows would need the base colour
//    map and a fragment stage to discard in; this pass has neither, which is the
//    honest statement that a leaf card casts the shadow of its quad. See
//    `render/shadow.c3` for what that costs and what would change it.
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
};

// Byte for byte what `mesh.slang` and `gpu/pipeline.c3` declare. This pass reads
// `light_view_projection` and `live_poses` and nothing else in it — the fields
// are here because the offsets are the contract, not because they are all used.
struct FrameBlock
{
    float4x4 view_projection;
    float4 light;
    float4x4* live_poses;
    float4x4 light_view_projection;
    float4 shadow;
};

// Byte for byte what `mesh.slang` and `shaders/skin.slang` declare.
struct SkinnedVertex
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
    float4 base_color;
    uint flags;
    uint skin_stride;
    float4 uv_transform;
};

// The mesh contract exactly, and nothing appended: there are no material
// uniforms in a depth pass, so `MESH_PUSH_FIELDS` is not merely satisfied here,
// it is the whole block. 24 bytes of the 128 every device offers.
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

    return weights.x * palette[base + joints.x]
         + weights.y * palette[base + joints.y]
         + weights.z * palette[base + joints.z]
         + weights.w * palette[base + joints.w];
}

// **No normal, no uv, no colour — and no `displace`.**
//
// The first three are absences that cost nothing: depth is a function of
// position, so a varying nothing reads is interpolation nobody pays for. The
// fourth is a real limitation and is stated rather than hidden: a
// `ShaderMaterial` with a `vertex:` body moves its surface in `material.slang`
// and this pass does not run that body, so such a mesh casts the shadow of its
// *undisplaced* geometry. `render/shadow.c3` carries what it would take to fix —
// the body would have to be assembled into this template too, which makes a
// shadow pipeline per material where today there is exactly one.
[shader("vertex")]
float4 vertexMain(uint vid : SV_VertexID, uint iid : SV_InstanceID) : SV_Position
{
    Draw draw = push.draw[0];
    Instance instance = push.instances[iid];

    float3 position = draw.positions[vid];

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
