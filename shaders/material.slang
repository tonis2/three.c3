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
};

// What every draw in the frame shares, written once per frame. 88 bytes.
struct FrameBlock
{
    float4x4 view_projection;
    float4 light;           // xyz: surface-to-light, world space. w: ambient floor.
    // This frame's live joint matrices, for characters posed from their bone nodes
    // rather than from a baked clip. One buffer per frame rather than per bucket,
    // which is what keeps a live character and a baked one in the same draw call.
    float4x4* live_poses;
};

// One vertex as the compute pass leaves it, byte for byte what `mesh.slang` and
// `shaders/skin.slang` declare. 24 bytes.
struct SkinnedVertex
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
    // rgb: albedo factor. a: the material's opacity, folded into the mesh's own
    // alpha on the C3 side. `fragmentMain` multiplies it by the instance's.
    float4 base_color;
    uint flags;
    // The mesh's vertex count, read only under FLAG_PRESKINNED. See `mesh.slang`.
    uint skin_stride;
    // xy repeat, zw offset. See `mesh.slang`.
    float4 uv_transform;
};

// **The three mesh fields come first, in this order, and material uniforms only
// ever go after them.** `check_push_block` requires each one at the offset
// `MeshPush` puts it at, so a uniform inserted anywhere but the end moves `draw`
// and the pipeline refuses the shader — which is the good outcome; the bad one is
// a layout that reflects differently and reads a record out of the middle of a
// float4. The three occupy 24 bytes of the 128 every device must offer, which is
// where `MATERIAL_UNIFORM_BUDGET`'s 104 comes from.
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

    return weights.x * palette[base + joints.x]
         + weights.y * palette[base + joints.y]
         + weights.z * palette[base + joints.z]
         + weights.w * palette[base + joints.w];
}

// Always bound, always valid — a 1x1 opaque white image when the material has no
// texture, so an untextured material and a textured one are the same descriptor
// layout and the same pipeline.
[vk::binding(0, 0)] Sampler2D base_color_map;

// The samplers the agent asked for, one line each, at bindings 1..N in the order
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
    // Which row of this material's table this copy selected, **already clamped**
    // to the rows the material declared. So `palette[s.variant]` is always in
    // bounds, whatever a script set, and a material with no table sees zero.
    uint variant;
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

    displace(v);

    output.world = v.position;
    // Built from the displaced position, which is the whole point: a vertex that
    // moved and a clip position that did not would be geometry lit and textured
    // as though it were somewhere it is not drawn.
    output.sv_position = mul(push.frame[0].view_projection, float4(v.position, 1.0));
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
