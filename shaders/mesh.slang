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
// as buffer device addresses in the push block and is indexed by SV_VertexID;
// an index buffer is still bound the ordinary way with vkCmdBindIndexBuffer,
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
};

// What every draw in the frame shares. Written once per frame rather than
// pushed per draw, which is what freed the room in the push block for
// instancing — see gpu/pipeline.c3.
struct FrameBlock
{
    float4x4 view_projection;
    float4 light;           // xyz: surface-to-light, world space. w: ambient floor.
};

struct PushData
{
    FrameBlock* frame;
    // Already offset to this bucket's first instance, so SV_InstanceID starts at
    // zero in every draw. Doing the arithmetic on the CPU is what keeps the
    // firstInstance-versus-InstanceIndex distinction from ever mattering here.
    Instance* instances;
    // Three separate streams rather than one interleaved Vertex: that is how
    // glTF stores them, so uploading is a memcpy per accessor and the vertex
    // shader reads what the file contained.
    float3* positions;
    float3* normals;
    float2* uvs;
    float4 base_color;      // rgb: albedo factor. a: material alpha, unused so far.
    uint flags;
};
[vk_push_constant] const PushData push;

// A stream that is absent is absent, not zero-filled: a null pointer costs no
// flag bit, but reading one is a device-lost rather than a fallback, so the
// flags say which streams are really there and the reads are guarded by them.
static const uint FLAG_HAS_NORMALS = 1u;
static const uint FLAG_HAS_UVS     = 2u;

// Always bound, always valid. With no material texture the binding carries a
// 1x1 opaque white image, so there is one pipeline and one descriptor layout
// rather than a permutation per material.
[vk::binding(0, 0)] Sampler2D base_color_map;

struct VertexOutput
{
    float3 normal : NORMAL;
    float2 uv : TEXCOORD0;
    // The instance's own colour, carried to the fragment stage because that is
    // where albedo is assembled. Interpolating it is a no-op — it is constant
    // across every vertex of an instance — and it is not marked
    // `nointerpolation` so that the two shaders declare the same varyings in the
    // same order, which `material.slang`'s header explains is a wire format
    // rather than a coincidence.
    float4 color : COLOR0;
    float4 sv_position : SV_Position;
};

[shader("vertex")]
VertexOutput vertexMain(uint vid : SV_VertexID, uint iid : SV_InstanceID)
{
    VertexOutput output;

    Instance instance = push.instances[iid];

    float3 position = push.positions[vid];
    float4 world = mul(instance.model, float4(position, 1.0));
    output.sv_position = mul(push.frame[0].view_projection, world);

    // An `if` rather than a ternary: a ternary lets the compiler evaluate both
    // sides and load through the null pointer it was meant to avoid.
    float3 normal = float3(0.0, 1.0, 0.0);
    if ((push.flags & FLAG_HAS_NORMALS) != 0) normal = push.normals[vid];
    output.normal = mul((float3x3)instance.normal, normal);

    output.uv = float2(0.0, 0.0);
    if ((push.flags & FLAG_HAS_UVS) != 0) output.uv = push.uvs[vid];

    output.color = instance.color;

    return output;
}

[shader("fragment")]
float4 fragmentMain(VertexOutput input) : SV_Target
{
    // The instance's colour multiplies the material's, so `mesh.color = [1, 0,
    // 0]` works with no material at all — which is the point of it being here
    // rather than only in `material.slang`. White is the identity and is what
    // every node starts at.
    float3 albedo = push.base_color.rgb * input.color.rgb;
    if ((push.flags & FLAG_HAS_UVS) != 0)
    {
        albedo *= base_color_map.Sample(input.uv).rgb;
    }

    // One hardcoded directional light and an ambient floor. A material model is
    // M5; anything more here is scope creep dressed as polish.
    float4 light = push.frame[0].light;
    float3 normal = normalize(input.normal);
    float lambert = max(dot(normal, normalize(light.xyz)), 0.0);
    float ambient = light.w;

    return float4(albedo * (ambient + (1.0 - ambient) * lambert), 1.0);
}
