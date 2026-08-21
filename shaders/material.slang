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

// One instance: where a copy of the mesh is, how its normals rotate, and the two
// things copies of one mesh may disagree about without costing a draw call. Byte
// for byte what `mesh.slang` and `scene/scene.c3` declare; 148 bytes.
struct Instance
{
    float4x4 model;
    float4x4 normal;
    float4 color;
    uint variant;
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
    // rgb: albedo factor. a: the material's opacity, folded into the mesh's own
    // alpha on the C3 side. `fragmentMain` multiplies it by the instance's.
    float4 base_color;
    uint flags;
    // xy repeat, zw offset. See `mesh.slang`. It is one of the **eight** fields
    // the mesh contract pins now, so material uniforms still only ever go after
    // it — and there are 52 bytes left for them rather than 68.
    float4 uv_transform;
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
    // Which row of this material's table this copy selected, **already clamped**
    // to the rows the material declared. So `palette[s.variant]` is always in
    // bounds, whatever a script set, and a material with no table sees zero.
    uint variant;
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

    output.color = instance.color;
    output.variant = instance.variant;

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
    // The instance colour is folded into albedo here, exactly as `mesh.slang`
    // folds it: a body that writes `return s.albedo * lambert(s.normal)` — the
    // default look — respects `mesh.color` without knowing it exists, and a body
    // that wants the raw value has `s.color`.
    // **The transform is applied to the sample and to `s.uv` alike.** A body that
    // samples its own texture with `s.uv` has to land on the same texel the
    // default shading does, or `material.repeat` would mean one thing without a
    // custom body and nothing at all with one.
    float2 uv = input.uv * push.uv_transform.xy + push.uv_transform.zw;
    s.albedo = push.base_color.rgb * srgb_to_linear(input.color.rgb);
    if ((push.flags & FLAG_HAS_UVS) != 0)
    {
        s.albedo *= base_color_map.Sample(uv).rgb;
    }
    s.normal = normalize(input.normal);
    s.uv = uv;
    s.position = input.world;
    s.color = float4(srgb_to_linear(input.color.rgb), input.color.a);
    // Clamped once, here, rather than at each use: an out-of-range index into a
    // push-constant array is undefined behaviour that reads whatever is next in
    // the block — a wrong colour with no error anywhere, which is precisely the
    // class of failure this project spends its comments on.
    s.variant = min(input.variant, MATERIAL_ROWS - 1u);

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
    return float4(shade(s), push.base_color.a * input.color.a);
}
