// three.c3 mesh pass.
//
// Rebuild with `c3c --trust=full build shaders`, or just run slangc yourself:
//
//     slangc shaders/mesh.slang -target spirv -emit-spirv-directly \
//         -fvk-use-entrypoint-name -force-glsl-scalar-layout -o shaders/mesh.spv
//
// The .spv is **read from disk at startup, never $embed-ed**. That is a
// deliberate departure from crig, which embeds and pays for it: `c3c build
// shaders` without --trust=full skips the exec, reports success, leaves the
// .spv untouched, and $embed picks up the previous binary — a shader edit that
// compiles cleanly and changes nothing on screen. Reading the file makes
// iteration a re-run rather than a rebuild, and makes M4 a one-function swap:
// load_spirv(path) becomes compile_slang(source) and nothing above it changes.
//
// **There is no vertex input state anywhere in this project.** Geometry arrives
// as buffer device addresses in the push block and is indexed by SV_VertexID;
// an index buffer is still bound the ordinary way with vkCmdBindIndexBuffer,
// which is independent of vertex bindings, so SV_VertexID arrives already
// resolved through it. Three.js's entire BufferGeometry attribute-binding layer
// never gets written.
//
// **Scalar layout, and the device is checked for it.** Apple M5 reports
// scalarBlockLayout under KosmicKrisp, the driver this project renders through
// (see gpu/device.c3), so the streams below are read as tightly packed float3
// and float2 — exactly the layout glTF hands over, with no CPU repack. Under
// standard std430 a float3 would take a 16-byte stride and every read here
// would be off by a third. gpu/pipeline.c3 refuses a device that lacks the
// feature rather than drawing garbage.

struct PushData
{
    float4x4 mvp;
    float4 base_color;      // rgb: albedo factor. a: material alpha, unused so far.
    float4 light;           // xyz: surface-to-light, world space. w: ambient floor.
    // Three separate streams rather than one interleaved Vertex: that is how
    // glTF stores them, so uploading is a memcpy per accessor and the vertex
    // shader reads what the file contained.
    float3* positions;
    float3* normals;
    float2* uvs;
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
    float4 sv_position : SV_Position;
};

[shader("vertex")]
VertexOutput vertexMain(uint vid : SV_VertexID)
{
    VertexOutput output;

    float3 position = push.positions[vid];
    output.sv_position = mul(push.mvp, float4(position, 1.0));

    // An `if` rather than a ternary: a ternary lets the compiler evaluate both
    // sides and load through the null pointer it was meant to avoid.
    output.normal = float3(0.0, 1.0, 0.0);
    if ((push.flags & FLAG_HAS_NORMALS) != 0) output.normal = push.normals[vid];

    output.uv = float2(0.0, 0.0);
    if ((push.flags & FLAG_HAS_UVS) != 0) output.uv = push.uvs[vid];

    return output;
}

[shader("fragment")]
float4 fragmentMain(VertexOutput input) : SV_Target
{
    float3 albedo = push.base_color.rgb;
    if ((push.flags & FLAG_HAS_UVS) != 0)
    {
        albedo *= base_color_map.Sample(input.uv).rgb;
    }

    // One hardcoded directional light and an ambient floor. A material model is
    // M5; anything more here is scope creep dressed as polish.
    float3 normal = normalize(input.normal);
    float lambert = max(dot(normal, normalize(push.light.xyz)), 0.0);
    float ambient = push.light.w;

    return float4(albedo * (ambient + (1.0 - ambient) * lambert), 1.0);
}
