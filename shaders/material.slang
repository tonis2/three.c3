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

// One instance: where a copy of the mesh is, and how its normals rotate. Byte
// for byte what `mesh.slang` and `scene/scene.c3` declare; 128 bytes.
struct Instance
{
    float4x4 model;
    float4x4 normal;
};

// What every draw in the frame shares, written once per frame. 80 bytes.
struct FrameBlock
{
    float4x4 view_projection;
    float4 light;           // xyz: surface-to-light, world space. w: ambient floor.
};

// **The seven mesh fields come first, in this order, and material uniforms only
// ever go after them.** `check_push_block` requires each one at the offset
// `MeshPush` puts it at, so a uniform inserted anywhere but the end moves
// `base_color` and the pipeline refuses the shader — which is the good outcome;
// the bad one is a layout that reflects differently and reads pointers out of
// the middle of a float4. The seven occupy 60 bytes of the 128 every device must
// offer, which is where `MATERIAL_UNIFORM_BUDGET`'s 68 comes from.
struct PushData
{
    FrameBlock* frame;
    Instance* instances;
    float3* positions;
    float3* normals;
    float2* uvs;
    float4 base_color;      // rgb: albedo factor. a: the alpha `fragmentMain` returns.
    uint flags;
    //@uniforms
};
[vk_push_constant] const PushData push;

// A stream that is absent is absent, not zero-filled: reading through a null
// pointer is a device-lost rather than a fallback, so the flags say which
// streams are really there and the reads are guarded by them.
static const uint FLAG_HAS_NORMALS = 1u;
static const uint FLAG_HAS_UVS     = 2u;

// Always bound, always valid — a 1x1 opaque white image when the material has no
// texture, so an untextured material and a textured one are the same descriptor
// layout and the same pipeline.
[vk::binding(0, 0)] Sampler2D base_color_map;

// **The contract with the agent.** Four values, all of them in world space or
// texture space, none of them a pointer and none of them a Vulkan concept. A
// body that only ever touches `Surface` cannot address the wrong buffer, which
// is most of what `plan.md` §4 means by "removes almost every Vulkan failure
// mode".
struct Surface
{
    float3 albedo;          // base colour factor, times the texture where there is one
    float3 normal;          // normalized, world space
    float2 uv;
    float3 position;        // world space
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
    float4 sv_position : SV_Position;
};

// `mesh.slang`'s light as a single factor, so a body can ask for the default
// look without reproducing it. `return s.albedo * lambert(s.normal);` is the
// same arithmetic `mesh.slang`'s `fragmentMain` performs — which is the property
// that makes a material a change of *shading* rather than a second renderer.
float lambert(float3 normal)
{
    float4 light = push.frame[0].light;
    float n_dot_l = max(dot(normal, normalize(light.xyz)), 0.0);
    float ambient = light.w;
    return ambient + (1.0 - ambient) * n_dot_l;
}

[shader("vertex")]
VertexOutput vertexMain(uint vid : SV_VertexID, uint iid : SV_InstanceID)
{
    VertexOutput output;

    Instance instance = push.instances[iid];

    float3 position = push.positions[vid];
    float4 world = mul(instance.model, float4(position, 1.0));
    output.world = world.xyz;
    output.sv_position = mul(push.frame[0].view_projection, world);

    // An `if` rather than a ternary: a ternary lets the compiler evaluate both
    // sides and load through the null pointer it was meant to avoid.
    float3 normal = float3(0.0, 1.0, 0.0);
    if ((push.flags & FLAG_HAS_NORMALS) != 0) normal = push.normals[vid];
    output.normal = mul((float3x3)instance.normal, normal);

    output.uv = float2(0.0, 0.0);
    if ((push.flags & FLAG_HAS_UVS) != 0) output.uv = push.uvs[vid];

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
    Surface s;
    s.albedo = push.base_color.rgb;
    if ((push.flags & FLAG_HAS_UVS) != 0)
    {
        s.albedo *= base_color_map.Sample(input.uv).rgb;
    }
    s.normal = normalize(input.normal);
    s.uv = input.uv;
    s.position = input.world;

    // **Alpha is not the agent's to return.** `shade` answers with linear rgb and
    // the alpha comes from the material's base colour, so a body cannot make
    // geometry invisible by accident — a failure that looks like nothing
    // rendered rather than like a shader bug, and therefore one an agent spends
    // its budget on the wrong file for.
    return float4(shade(s), push.base_color.a);
}
