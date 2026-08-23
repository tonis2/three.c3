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
};

// What every draw in the frame shares. Written once per frame rather than
// pushed per draw, which is what freed the room in the push block for
// instancing — see gpu/pipeline.c3.
struct FrameBlock
{
    float4x4 view_projection;
    float4 light;           // xyz: surface-to-light, world space. w: ambient floor.
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
// `both_shaders_declare_the_same_record` checks this text against the copy in
// `material.slang`.
struct Draw
{
    // Three separate streams rather than one interleaved Vertex: that is how
    // glTF stores them, so uploading is a memcpy per accessor and the vertex
    // shader reads what the file contained.
    float3* positions;
    float3* normals;
    float2* uvs;
    // glTF's COLOR_0, if the file carried one. **Nothing in this shader reads
    // it**, and that is not an oversight: a colour attribute changes no pixel of
    // a `MeshLambertMaterial` here, so the only stage that can see it is a
    // material body — `material.slang` hands it over as `s.vertex_color`. It is
    // declared here because the record is one struct shared by both shaders and
    // an offset that differed between them would read geometry from the wrong
    // address.
    float4* colors;
    // rgb: albedo factor. a: the alpha this returns — the mesh's own alpha
    // times `material.opacity`, folded together on the C3 side so the shader
    // sees one number. Ignored by an opaque pipeline, which writes no alpha at
    // all; `BlendMode` says which pipelines read it.
    float4 base_color;
    uint flags;
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

    Draw draw = push.draw[0];
    Instance instance = push.instances[iid];

    float3 position = draw.positions[vid];
    float4 world = mul(instance.model, float4(position, 1.0));
    output.sv_position = mul(push.frame[0].view_projection, world);

    // An `if` rather than a ternary: a ternary lets the compiler evaluate both
    // sides and load through the null pointer it was meant to avoid.
    float3 normal = float3(0.0, 1.0, 0.0);
    if ((draw.flags & FLAG_HAS_NORMALS) != 0) normal = draw.normals[vid];
    output.normal = mul((float3x3)instance.normal, normal);

    output.uv = float2(0.0, 0.0);
    if ((draw.flags & FLAG_HAS_UVS) != 0) output.uv = draw.uvs[vid];

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

[shader("fragment")]
float4 fragmentMain(VertexOutput input) : SV_Target
{
    // The instance's colour multiplies the material's, so `mesh.color = [1, 0,
    // 0]` works with no material at all — which is the point of it being here
    // rather than only in `material.slang`. White is the identity and is what
    // every node starts at.
    Draw draw = push.draw[0];

    float3 albedo = draw.base_color.rgb * srgb_to_linear(input.color.rgb);
    if ((draw.flags & FLAG_HAS_UVS) != 0)
    {
        albedo *= base_color_map.Sample(input.uv * draw.uv_transform.xy + draw.uv_transform.zw).rgb;
    }

    // One hardcoded directional light and an ambient floor. A material model is
    // M5; anything more here is scope creep dressed as polish.
    float4 light = push.frame[0].light;
    float3 normal = normalize(input.normal);
    float lambert = max(dot(normal, normalize(light.xyz)), 0.0);
    float ambient = light.w;

    // The material's alpha times this copy's own, exactly as the rgb above
    // multiplies the two. `mesh.color = [r, g, b, a]` therefore fades one
    // instance out of a thousand sharing a draw call — and does nothing at all
    // unless the material was built transparent, because an opaque pipeline
    // discards this channel. It read a hardcoded `1.0` until blending existed.
    return float4(albedo * (ambient + (1.0 - ambient) * lambert), draw.base_color.a * input.color.a);
}
