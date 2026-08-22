// three.c3 post-processing template — `plan.md` §4's tier 2, applied to the
// whole frame instead of to a surface.
//
// **This is a template. It is not valid Slang as it stands and nothing compiles
// it directly.** `src/shader/post_source.c3` reads it, replaces three marker
// lines, and hands the result to `compile_slang_cached` as a string — the same
// arrangement `shaders/material.slang` has, through the same assembler
// (`src/shader/assemble.c3`), so the `#line` bracketing that puts a diagnostic
// on the agent's own line works here for free.
//
// The markers are whole lines, matched after trimming, so their indentation is
// free. Each is replaced by zero or more lines:
//
//     //@uniforms   one field per post uniform, appended to the push block
//     //@defines    one `#define name (push.name)` per uniform
//     //@shade      `#line`, the agent's body, `#line` back, `#undef`
//
// **There is no `//@rows`.** A material's uniform arrays are a table indexed by
// `Surface.variant`, the per-instance row selector — and a post pass has no
// instances. One frame, one draw, one row.
//
// ## What is deliberately absent
//
// No `Instance`, no `FrameBlock`, no geometry pointers, no depth: this pass
// draws three vertices with no vertex input and reads one image. That is also
// why its push block shares nothing with the mesh contract — `POST_PUSH_FIELDS`
// pins `info` at 0 and nothing else, and `MeshPipeline.init_post` checks against
// that list rather than `MESH_PUSH_FIELDS`.

// What the pass knows about itself, and what the agent's uniforms are appended
// to. `info` is first and 16 bytes, which is what `POST_PUSH_FIELDS` pins:
//
//     xy  the target's extent in pixels
//     z   seconds since the shader was set — the clock starts at `setPost`
//     w   unused, and reserved rather than removed: a float4 is the alignment
//         a scalar-layout block wants at offset 0 anyway, so the fourth
//         component is free and a fifth field would not be.
struct PushData
{
    float4 info;
    //@uniforms
};
[vk_push_constant] const PushData push;

// The frame the scene was rendered into, as `src/render/post.c3` created it:
// `R8G8B8A8_SRGB`, so **the sampler decodes to linear on read**. A body works in
// linear throughout and the `_SRGB` attachment this shader writes re-encodes on
// the way out, which closes the round trip by format rather than by arithmetic.
// An identity body is therefore an identity, to within eight bits.
[vk::binding(0, 0)] Sampler2D scene;

// The samplers the agent asked for, at bindings 1..N in declaration order —
// `shaders/material.slang` has the argument for why the indices are generated
// rather than written. A post pass wants them for the things a frame cannot
// supply about itself: a colour ramp to grade through, a noise field to distort
// or dither by, a mask that says where an effect applies.
//
// Unlike a material's, these are not sampled with a surface's uv. `p.uv` is the
// screen, so a lookup wants a coordinate the body builds — `p.color.r` for a
// ramp, `p.uv * resolution / 256` for tiled noise that does not stretch with the
// window.
//@textures

// **The contract with the agent.** Four values, none of them a Vulkan concept
// and none of them a pointer. A body that only ever touches `Post` cannot
// address the wrong buffer — the same claim `Surface` makes in
// `material.slang`, over a much smaller surface because there is much less here.
struct Post
{
    // This pixel of the rendered scene, **linear** — the sampler decoded it.
    float3 color;
    // Where this pixel is: 0..1 across the frame, with (0, 0) at the top left,
    // which is both the texture convention and the screen convention here.
    //
    // **No flip appears anywhere in this file**, and that is a decision made in
    // `PostPass.record` rather than an omission here. Every other pass in this
    // project sets a *negative*-height viewport, which undoes Vulkan's Y-down
    // NDC so that a glm-convention projection matrix lands the right way up.
    // There is no projection in this pass: the three vertices below are already
    // NDC, and `uv` is the number they were built from. So the post pass sets a
    // positive-height viewport, `uv.y` and the framebuffer row rise together,
    // and sampling `input.uv` reads the pixel that is being written. Under the
    // negative viewport the frame would come back upside down with nothing in
    // the API objecting — `three_tests::post` pins it against an asymmetric
    // fixture for exactly that reason.
    float2 uv;
    // The target's extent in pixels. `1.0 / p.resolution` is one texel, which is
    // what a blur or an edge filter needs to step by.
    float2 resolution;
    // Seconds since the shader was set, as a float. Wall clock, not a game
    // clock: nothing here knows about a simulation. `plan.md` §2 has the
    // deferral.
    float time;
};

struct VertexOutput
{
    float2 uv : TEXCOORD0;
    float4 sv_position : SV_Position;
};

// **One triangle, not two, and no vertex buffer at all.** The three vertices are
// computed from `SV_VertexID` — `cmdDraw(3, 1, 0, 0)` with an empty vertex input
// state, which is already how every pipeline in this project feeds itself
// (geometry arrives as buffer device addresses elsewhere; here it arrives as
// arithmetic).
//
// A single oversized triangle rather than a quad because a quad's diagonal makes
// the two halves of the frame two separate rasteriser invocations that meet along
// a seam; one triangle has no seam and issues one primitive.
//
//     vid  uv        clip xy
//     0    (0, 0)    (-1, -1)
//     1    (2, 0)    ( 3, -1)
//     2    (0, 2)    (-1,  3)
//
// The winding is clockwise on screen, which is the opposite of everything else
// this project draws — hence `CULL_MODE_NONE`, statically, in
// `MeshPipeline.init_post`. Getting that wrong is an empty frame with no
// validation message, so it is stated in both places.
[shader("vertex")]
VertexOutput vertexMain(uint vid : SV_VertexID)
{
    VertexOutput output;
    float2 uv = float2(float((vid << 1) & 2), float(vid & 2));
    output.uv = uv;
    output.sv_position = float4(uv * 2.0 - 1.0, 0.0, 1.0);
    return output;
}

// The uniforms arrive as bare names, `#define`d here and `#undef`ed straight
// after the body so the substitution reaches the agent's lines and nothing else.
// `material.slang` has the full argument; the hazard is identical — a uniform
// named `w` would otherwise rewrite `push.info.w` below.
//@defines
//@shade

[shader("fragment")]
float4 fragmentMain(VertexOutput input) : SV_Target
{
    Post p;
    p.uv = input.uv;
    p.resolution = push.info.xy;
    p.time = push.info.z;
    p.color = scene.Sample(input.uv).rgb;

    // **Alpha is not the agent's to return**, for `material.slang`'s reason and
    // one more: this is the last thing written before the blit and the readback,
    // and `Target.decode_readback` forces alpha opaque regardless. A body that
    // could dim it would be a body that could make a screenshot look different
    // from the window.
    return float4(post(p), 1.0);
}
