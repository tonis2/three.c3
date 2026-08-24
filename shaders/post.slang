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
// No `Instance`, no `FrameBlock`, no geometry pointers: this pass draws three
// vertices with no vertex input and reads four images — the pass before it, the
// scene (which are the same image on a chain of one), the frame's depth buffer,
// and whichever earlier pass this one named. That is also why its push block shares nothing with the mesh contract
// — `POST_PUSH_FIELDS` pins `info` and `planes` and nothing else, and
// `MeshPipeline.init_post` checks against that list rather than
// `MESH_PUSH_FIELDS`.

// What the pass knows about itself, and what the agent's uniforms are appended
// to. `info` is first and 16 bytes, `planes` follows it and is 8 — together they
// are what `POST_PUSH_FIELDS` pins, and the agent's uniforms start at 24.
//
//     info.xy   the target's extent in pixels
//     info.z    seconds since the shader was set — the clock starts at `setPost`
//     info.w    unused, and reserved rather than removed: a float4 is the
//               alignment a scalar-layout block wants at offset 0 anyway, so
//               the fourth component is free and a fifth field would not be.
//     planes.x  the camera's near plane, in world units
//     planes.y  its far plane
//
// The planes are here rather than in `info.w` because linearising a device depth
// needs both of them, and they cost the agent 8 bytes of a 128-byte block once
// rather than costing a body that wants `p.depth` a uniform it has to remember
// to set.
struct PushData
{
    float4 info;
    float2 planes;
    //@uniforms
};
[vk_push_constant] const PushData push;

// **The two reserved samplers, and the whole of what a chain edge is.**
//
// `prev` is what the pass before this one wrote; `scene` is always image A, the
// frame the geometry was rendered into. On a chain of one they are the same
// image, which is what makes every post shader written before the chain existed
// keep working with no edit — `p.color == p.scene` there.
//
// The second one is the non-adjacent read, and it is a binding rather than a
// dependency solver on purpose: bloom is `blur(bright(scene)) + scene`, which
// wants the original three passes later, and that is the only edge anybody
// actually reaches for. `plan.md` §13 has the argument.
//
// Their formats differ and both are read as linear:
//
//     prev    R16G16B16A16_SFLOAT for a chain pass, or image A for the first —
//             a float image holds raw linear values and needs no decode, so a
//             pass may write above 1.0 and the next one still sees it.
//     scene   image A, R8G8B8A8_SRGB, so **the sampler decodes to linear**.
//
// Nothing here writes `_SRGB`. Every pass a script writes reads float and writes
// float; the engine's own tonemap is the only thing that encodes, and it is
// always last. That is what keeps one pipeline shape for every body and makes
// reordering a chain free rather than a recompile.
[vk::binding(0, 0)] Sampler2D prev;
[vk::binding(1, 0)] Sampler2D scene;

// **The third reserved binding: the frame's own depth buffer.**
//
// Not a colour image and not read like one. It is `D32_SFLOAT` in
// `DEPTH_STENCIL_READ_ONLY_OPTIMAL`, sampled with a *nearest* sampler — see
// `PostPass.ensure_sampler` for why linear is both unavailable and meaningless —
// and its red channel is the non-linear device depth the rasteriser wrote.
//
// A body never touches this: `p.depth` is the same texel already reconstructed
// into world units, and that is the whole reason this binding is reserved rather
// than being a texture a script attaches. `plan.md` §2 named the alternative —
// "shipping the near/far reconstruction with it or shipping a footgun" — and
// this is the first of the two.
[vk::binding(2, 0)] Sampler2D depth_buffer;

// **The fourth reserved binding: another pass's output.**
//
// `plan.md` §2's "a pass wanting a third source". `prev` and `scene` are
// adjacency and the original picture, and between them they cover bloom; what
// they do not cover is a pass reading something from the *middle* of the chain —
// a blurred copy that two later passes both want, a mask one pass built for
// another to apply.
//
// A pass says which one by handle: `three.addPass({ fragment, reads: blurred })`.
// It is one index and not an edge list, which is what keeps the chain's barriers
// derived from adjacency — `render/chain.c3` has that argument, and
// `PostPass.output_of` has the whole cost of it: a pass somebody taps writes into
// an image of its own instead of a ping-pong slot.
//
// **Bound to image A when nothing was named**, which makes `p.tap` the rendered
// scene — what `p.scene` gives, and this chain's existing rule for a source that
// is not distinct (`p.color == p.scene` on a chain of one). The alternative,
// refusing, is not available: this template fills `p.tap` for every body, so
// Slang keeps the sampler whether the agent's lines mention it or not and the
// reflected layout cannot tell "reads it" from "does not".
//
// **Named `tap_image` and not `tap`**, unlike `prev` and `scene`, which share
// their names with their fields. `tap` is a word shader bodies use — "a nine-tap
// blur" — and `examples/blend_post.js` had a helper called exactly that; a
// reserved global by that name turns somebody's own function into a conflicting
// declaration. `depth_buffer` is named for the same reason. The *field* stays
// `p.tap`, which is what a body reads.
//
// `p.tap` is the same-pixel sample, as `p.color` is for `prev`.
[vk::binding(3, 0)] Sampler2D tap_image;

// The samplers the agent asked for, at bindings 4..N in declaration order —
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
    // This pixel of whatever ran before this pass, **linear**. On the first pass
    // of a chain — and on every chain of one — that is the rendered scene, which
    // is why this field did not change meaning when the chain arrived.
    float3 color;
    // This pixel of the rendered scene, **linear**, whatever else has run since.
    // Equal to `color` on the first pass. A later pass wanting the picture as the
    // geometry left it reads this rather than trying to undo what came between.
    float3 scene;
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
    // Seconds since the shader was set, as a float. The **game** clock — so a
    // paused world has a still post chain, and `three.clock.timeScale = 0.5`
    // halves an animated effect along with everything else. `scene/clock.c3`.
    float time;
    // How far this pixel is from the camera, **in world units, along the view
    // direction**. Near-plane distance on the closest thing drawn, far-plane
    // distance on a pixel nothing was drawn into.
    //
    // **Already linear**, which is the whole design of this field. The device
    // depth is a reciprocal distribution — half its range covers the first few
    // percent of the frustum — and every body that wanted it would otherwise
    // write the same reconstruction, or forget to and get a picture where fog
    // and focus bunch up against the camera. `plan.md` §2: "do it with `p.depth`
    // already linearized to world units, rather than handing over the raw
    // buffer".
    //
    // Compare it against distances, not against 0..1: `p.depth > 20` is twenty
    // units away. `(p.depth - near) / (far - near)` is the normalised version if
    // a body wants one, and the planes are not exposed because a body that needs
    // them is a body doing the reconstruction this field already did.
    float depth;
    // This pixel of the pass named by `reads`, **linear**. The rendered scene
    // when none was named, which is `p.scene` — see the binding above for why
    // that is a definition rather than a fallback.
    //
    // The sampler is in scope as `tap`, for `prev`'s reason: a body wanting a
    // *different* pixel of it — which is most of why a third source is worth
    // having — reads `tap.Sample(uv)` directly.
    float3 tap;
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
    p.color = prev.Sample(input.uv).rgb;
    p.scene = scene.Sample(input.uv).rgb;
    p.tap = tap_image.Sample(input.uv).rgb;

    // The reciprocal undone. `d` is what the rasteriser wrote under a standard
    // Vulkan 0..1 perspective projection, and
    //
    //     z = near * far / (far - d * (far - near))
    //
    // is its inverse. At d = 0 that is `near` and at d = 1 it is `far`, which is
    // what makes a pixel nothing was drawn into read as the far plane rather
    // than as a division by zero: the clear value is 1.0.
    float d = depth_buffer.Sample(input.uv).r;
    float near = push.planes.x;
    float far = push.planes.y;
    float span = far - d * (far - near);
    // A guard rather than an assumption. `span` is positive for every d in 0..1
    // with sane planes, and a runtime that has not set them yet — both zero —
    // would otherwise put a NaN into every body that reads `p.depth`.
    p.depth = span > 1e-6 ? near * far / span : far;

    // **Alpha is not the agent's to return**, for `material.slang`'s reason and
    // one more: the last thing this chain writes goes to the blit and the
    // readback, and `Target.decode_readback` forces alpha opaque regardless. A
    // body that could dim it would be a body that could make a screenshot look
    // different from the window.
    return float4(post(p), 1.0);
}
