// three.c3 compute skinning.
//
// **Compiled at runtime from this file**, like `mesh.slang` and `material.slang`
// and through the same `src/shader/compile.c3` — there is no build step and no
// .spv on disk. The one difference is the stage: this module has a single
// `[shader("compute")]` entry point and no graphics pipeline anywhere near it.
//
// ## What this is for, stated honestly
//
// It does exactly the same arithmetic `mesh.slang`'s `skin_matrix` does, and for
// a mesh drawn once per frame it is **strictly more work**: the same blend, plus
// 24 bytes a vertex written here, plus those bytes read back by the vertex
// shader, plus a dispatch and a barrier. It also costs memory the vertex path
// does not spend — one posed copy of the mesh per instance, per frame in flight.
//
// It earns that back in exactly one situation: the same skinned mesh drawn
// **more than once in a frame**. A vertex shader pays the blend once per draw; a
// dispatch pays it once per frame however many passes read the result. A shadow
// map plus the main pass is roughly break-even, a depth prepass on top of that is
// a clear win, and `plan.md` §13 is where the pass count that decides it lives.
//
// The second reason is not about speed at all: posed vertices in memory are the
// only way to raycast against the pose a character is actually in, rather than
// against the bind-pose box §3/S4 settles for.
//
// So this is opt-in per character — `instantiate({ skinning: 'compute' })` — and
// the default stays in the vertex shader. Routing a crowd through here would be
// paying the memory for a payoff that needs a second pass to arrive.
//
// ## What it deliberately does not do
//
// **The output stays in the character's own space**, not world space. Multiplying
// by the model matrix here would save one multiply in the vertex shader and would
// mean the posed vertices could not be shared by two passes with different
// notions of where the character is — and sharing across passes is the entire
// reason this file exists.

// Byte for byte what `mesh.slang` and `scene/scene.c3` declare.
struct Instance
{
    float4x4 model;
    float4x4 normal;
    float4 color;
    uint variant;
    uint pose;
    // The frame a crossfade is coming out of, and how much of it is still showing.
    // Mixed here for the same reason and with the same lie `mesh.slang` names: a
    // character posed by this pass has to fade the way one posed by the vertex
    // shader does, or switching `skinning: 'compute'` on changes how it looks.
    uint pose_from;
    float blend;
    // Which slice of `morph_weights` this copy reads, plus one, or zero for a copy
    // that does not morph. **Last, like the C3 struct** — the field order here is
    // a wire format, not a preference.
    uint morph;
};

// Byte for byte what `mesh.slang` and `gpu/pipeline.c3` declare. One thread
// writes both halves and one vertex-shader invocation reads them.
struct SkinnedVertex
{
    float3 position;
    float3 normal;
};

// One vertex's displacement for one morph target. Byte for byte what
// `mesh.slang` and `gpu/pipeline.c3` declare — displacements and not positions,
// because that is what composes.
struct MorphDelta
{
    float3 position;
    float3 normal;
};

// Everything one bucket's dispatch needs. Its own 128 bytes, competing with
// nothing — there are no material uniforms in a compute pass, which is why this
// can be eleven fields where the draw path had to move its contract into memory.
struct SkinPush
{
    float3* positions;
    float3* normals;
    uint4* joints;
    float4* weights;
    // Already offset to this bucket's first instance, exactly as the draw path
    // offsets it, so `iid` starts at zero here for the same reason it does there.
    Instance* instances;
    // The two palettes. Which one a copy reads is a property of the instance, not
    // of the bucket — the same one-bit selector `mesh.slang` uses, and reproduced
    // rather than resolved on the CPU so that a live character and a baked one
    // can sit in one dispatch.
    float4x4* baked;
    float4x4* live;
    // This bucket's slice of the frame's output buffer.
    SkinnedVertex* output;
    // The mesh's morph targets and the frame's weights, both null when nothing
    // morphs. **The displacement has to happen here and not in the vertex shader**
    // for a pre-skinned bucket: this pass writes the posed vertices the draw then
    // reads, so a morph applied afterwards would be applied to a vertex the joints
    // had already moved — and turning `skinning: 'compute'` on would change the
    // character's face.
    MorphDelta* morph;
    float* morph_weights;
    uint vertex_count;
    uint instance_count;
    uint flags;
    uint morph_targets;
};
[vk_push_constant] const SkinPush push;

static const uint FLAG_HAS_NORMALS = 1u;
static const uint POSE_LIVE = 0x80000000u;
static const uint POSE_MASK = 0x7fffffffu;

// 64 threads: a mesh is thousands of vertices and the dispatch is one dimension,
// so the only thing this number decides is how many threads the tail wastes.
// Sixty-four is the largest that is a subgroup multiple on every device this runs
// on.
// The four influences of one vertex against one palette, summed into the matrix
// that poses it. `mesh.slang` carries the same function for the same reason: a
// crossfade spends it twice, once per frame it sits between.
float4x4 blend_joints(float4x4* palette, uint base, uint4 joints, float4 weights)
{
    return weights.x * palette[base + joints.x]
         + weights.y * palette[base + joints.y]
         + weights.z * palette[base + joints.z]
         + weights.w * palette[base + joints.w];
}

[shader("compute")]
[numthreads(64, 1, 1)]
void computeMain(uint3 thread : SV_DispatchThreadID)
{
    uint index = thread.x;
    uint total = push.vertex_count * push.instance_count;
    // The tail. A dispatch is rounded up to whole workgroups, so the last one is
    // partly out of range — and out of range here is a write past the end of the
    // output buffer rather than a wasted lane.
    if (index >= total) return;

    uint iid = index / push.vertex_count;
    uint vid = index - iid * push.vertex_count;

    Instance instance = push.instances[iid];

    // An `if` rather than a ternary, the same as the draw path: one of these two
    // pointers is null on any given dispatch.
    float4x4* palette = push.baked;
    if ((instance.pose & POSE_LIVE) != 0) palette = push.live;
    uint base = instance.pose & POSE_MASK;

    float3 position = push.positions[vid];
    float3 normal = float3(0.0, 1.0, 0.0);
    if ((push.flags & FLAG_HAS_NORMALS) != 0) normal = push.normals[vid];

    // Before the blend, exactly as `mesh.slang` does it and for the reason its
    // `apply_morph` gives: a blend shape is authored against the rest mesh.
    if (push.morph_targets != 0 && instance.morph != 0)
    {
        uint morph_base = instance.morph - 1;
        for (uint t = 0; t < push.morph_targets; t++)
        {
            float amount = push.morph_weights[morph_base + t];
            if (amount == 0.0) continue;
            MorphDelta delta = push.morph[t * push.vertex_count + vid];
            position += amount * delta.position;
            normal += amount * delta.normal;
        }
    }

    uint4 joints = push.joints[vid];
    float4 weights = push.weights[vid];

    float4x4 pose = blend_joints(palette, base, joints, weights);
    if (instance.blend > 0.0)
    {
        float4x4 from = blend_joints(palette, instance.pose_from & POSE_MASK, joints, weights);
        pose = pose + (from - pose) * instance.blend;
    }

    SkinnedVertex skinned;
    skinned.position = mul(pose, float4(position, 1.0)).xyz;
    skinned.normal = mul((float3x3)pose, normal);

    push.output[index] = skinned;
}
