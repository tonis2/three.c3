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
    // Where this copy's joint matrices start, in matrices, and which buffer they
    // are in — the top bit is POSE_LIVE and the rest is the offset.
    //
    // **The third thing two copies of a mesh may disagree about, and the one that
    // makes a crowd affordable.** A hundred characters mid-stride at a hundred
    // different phases differ by this one uint: they key different frames out of
    // the same baked table and stay a single vkCmdDrawIndexed. Zero on a mesh with
    // no skin, and pointing at the skin's rest pose on one that has never played.
    uint pose;
};

// What every draw in the frame shares. Written once per frame rather than
// pushed per draw, which is what freed the room in the push block for
// instancing — see gpu/pipeline.c3.
struct FrameBlock
{
    float4x4 view_projection;
    float4 light;           // xyz: surface-to-light, world space. w: ambient floor.
    // This frame's live joint matrices — the characters whose pose is computed
    // from their bone nodes rather than read out of a baked table.
    //
    // **Here rather than in the draw record**, because it is one buffer for the
    // whole frame while a record is per bucket: a live character and a baked one
    // sharing a mesh and a material are one bucket, and giving the record a single
    // palette pointer would have forced them apart into two draws. Null in a frame
    // where nothing is live, which is every frame of a scene with no skeletons.
    float4x4* live_poses;
    // Where the light is looking from, as one matrix: the orthographic
    // view-projection `render/shadow.c3` fitted around the scene this frame.
    // `shaders/shadow.slang` renders the depth map with it and `shadow_factor`
    // below reads the map back with the same matrix, which is what makes the two
    // agree — one fit, written once per frame, used by both ends.
    //
    // Identity, and unread, in a frame with no shadow pass: `shadow.w` is what
    // says which, and it is zero then.
    float4x4 light_view_projection;
    // The four numbers the lookup needs, and `shadow.w` is the switch.
    //
    //   x  one shadow texel in uv, so the PCF taps are a texel apart whatever
    //      size the map was created at
    //   y  the depth bias, in the light's ndc depth units — what a script sets
    //      as `three.light.shadow.bias`
    //   z  how far along the surface normal a sample is nudged before it is
    //      projected, in world units. Derived from the fitted extent rather than
    //      set by anybody, so it scales with the scene — see `render/shadow.c3`
    //   w  how dark a shadow is, 0 to 1, and **0 is also how "no shadow pass ran
    //      this frame" is spelled**. One number for both because the shader's
    //      answer is the same either way: an intensity of zero and no map are
    //      both "nothing is occluded", and a second flag would be a second thing
    //      to keep in step with the first.
    float4 shadow;
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
// `every_shader_declares_the_same_contract` checks this text against the copies
// in `material.slang` and `shadow.slang`.
// One vertex as the compute pass leaves it: posed, in the character's own space,
// one copy per instance.
//
// Position and normal interleaved, unlike the geometry streams above, because
// these two are written by one thread and read by one thread — the pair is the
// unit of work, and splitting it would make two scattered writes per vertex out
// of one. `shaders/skin.slang` writes it and `gpu/pipeline.c3` declares the same
// 24 bytes.
struct SkinnedVertex
{
    float3 position;
    float3 normal;
};

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
    // glTF's JOINTS_0 and WEIGHTS_0: which four joints move this vertex and how
    // strongly. Widened to uint4 on upload from whatever width the file stored
    // them at, and the weights renormalised — glTF blends without normalising, so
    // a vertex whose weights sum to 0.8 sits at 80% of the way to the origin and
    // the mesh visibly deflates.
    uint4* joints;
    float4* weights;
    // This asset's baked joint matrices: every clip of every skin, sampled at a
    // fixed rate and folded through the inverse bind pose once at load. Immutable
    // for the life of the asset, which is the whole reason a crowd is free — there
    // is nothing to upload per frame and nothing that can tear.
    //
    // Null on a bucket with no skin, and unread on one the compute pass already
    // posed. A *live* character's matrices are not in here; see
    // `FrameBlock.live_poses` and `skin_matrix`.
    float4x4* palette;
    // Where the compute pass wrote this bucket's posed vertices, one copy of the
    // mesh per instance, or null on every bucket it did not run for.
    //
    // **A pointer of its own rather than swapping `positions` for it**, which was
    // the first shape and was wrong: `positions` is also what a material body
    // reads as `Vertex.local`, and a body that sizes a ripple by the mesh's own
    // length wants the *bind* pose there. Overloaded, the ripple would slide
    // across the surface as the character moved — an effect that looks like a
    // material bug and is a record that changed meaning underneath it.
    SkinnedVertex* posed;
    // rgb: albedo factor. a: the alpha this returns — the mesh's own alpha
    // times `material.opacity`, folded together on the C3 side so the shader
    // sees one number. Ignored by an opaque pipeline, which writes no alpha at
    // all; `BlendMode` says which pipelines read it.
    float4 base_color;
    uint flags;
    // The mesh's vertex count, and only meaningful under FLAG_PRESKINNED: the
    // compute pass writes one posed copy of the mesh per instance into a single
    // buffer, so a vertex is found at `iid * skin_stride + vid`. Zero everywhere
    // else, where the streams hold one shared copy and SV_VertexID indexes it
    // directly.
    uint skin_stride;
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
// The bucket carries joints and weights and its vertices are posed here.
static const uint FLAG_HAS_SKIN    = 8u;
// The bucket's vertices were posed by the compute pass before the render pass
// began, so `positions` and `normals` are already in the character's posed local
// space and this shader must not blend them a second time. The two skin flags are
// mutually exclusive by construction — `render/pass.c3` sets one or the other.
static const uint FLAG_PRESKINNED  = 16u;

// `Instance.pose` is an offset in matrices with a selector in its top bit: set
// means this frame's live palette, clear means the asset's baked table.
static const uint POSE_LIVE = 0x80000000u;
static const uint POSE_MASK = 0x7fffffffu;

// Always bound, always valid. With no material texture the binding carries a
// 1x1 opaque white image, so there is one pipeline and one descriptor layout
// rather than a permutation per material.
[vk::binding(0, 0)] Sampler2D base_color_map;

// **Binding 1 is the shadow map, in every shader that shades a surface.** It is
// reserved the way `base_color_map` is — declared by the template rather than by
// anything a script writes — which is why `MATERIAL_BINDING_FIRST` is 2 and an
// agent's first sampler is numbered from there. `shader/assemble.c3` has the
// argument for why reserving a binding is a constant and never a shared bump.
//
// **Always bound and always valid, exactly like binding 0.** With no shadow pass
// this carries the same 1x1 opaque white image an untextured material samples,
// and white is the right answer by construction: a depth of 1.0 is the far plane,
// nothing is in front of anything, and the comparison below comes out lit. So
// there is one pipeline and one descriptor layout whether shadows are on or off,
// and turning them on is a different image in the same slot rather than a
// recompile.
[vk::binding(1, 0)] Sampler2D shadow_map;

// The four influences of one vertex, blended into the matrix that poses it.
//
// **Which buffer the palette lives in is a property of the instance, not of the
// bucket.** A baked copy reads the asset's immutable table through `draw.palette`;
// a live one — a character whose bones a script can write, for IK or a look-at —
// reads this frame's palette through the frame block. The selector is one bit of
// `Instance.pose` and it is uniform across an instance, so this is a scalar
// select and not divergence, and the two kinds of character stay in one bucket.
//
// An `if` rather than a ternary, for the reason `vertexMain` gives below: a
// ternary invites the compiler to evaluate both sides, and one of these two
// pointers is null on any given draw.
float4x4 skin_matrix(Draw draw, Instance instance, uint vid)
{
    float4x4* palette = draw.palette;
    if ((instance.pose & POSE_LIVE) != 0) palette = push.frame[0].live_poses;
    uint base = instance.pose & POSE_MASK;

    uint4 joints = draw.joints[vid];
    float4 weights = draw.weights[vid];

    // Summed rather than interpolated: linear blend skinning is a weighted sum of
    // the joint matrices, and the weights are normalised on upload so the sum is
    // affine. This is the one place the four influences per vertex are spent.
    return weights.x * palette[base + joints.x]
         + weights.y * palette[base + joints.y]
         + weights.z * palette[base + joints.z]
         + weights.w * palette[base + joints.w];
}

struct VertexOutput
{
    float3 normal : NORMAL;
    float2 uv : TEXCOORD0;
    // Where this fragment is in the world.
    //
    // **This shader had no such varying until shadows existed**, and its absence
    // was documented as a positive statement: `material.slang`'s copy still says
    // "mesh.slang carries no world position because nothing it computes needs
    // one". A shadow lookup is exactly a thing that needs one — the light's
    // matrix has to be applied to a world position and there is nowhere else to
    // get it — so the sentence stopped being true and the varying arrived. Same
    // semantic and same slot as `material.slang`'s, which is what keeps the two
    // sets of varyings the parallel pair its header claims they are.
    float3 world : TEXCOORD1;
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

    // An `if` rather than a ternary: a ternary lets the compiler evaluate both
    // sides and load through the null pointer it was meant to avoid.
    float3 normal = float3(0.0, 1.0, 0.0);
    if ((draw.flags & FLAG_HAS_NORMALS) != 0) normal = draw.normals[vid];

    // The two ways a vertex gets posed, and a bucket is at most one of them.
    //
    // **Before the model matrix either way**, because a joint matrix is in the
    // character's own space and the model matrix is what puts the character in the
    // world. Doing it the other way round poses the mesh around the world origin,
    // which looks like a rig that explodes the moment the character walks away
    // from it.
    if ((draw.flags & FLAG_HAS_SKIN) != 0)
    {
        float4x4 pose = skin_matrix(draw, instance, vid);
        position = mul(pose, float4(position, 1.0)).xyz;
        normal = mul((float3x3)pose, normal);
    }
    else if ((draw.flags & FLAG_PRESKINNED) != 0)
    {
        // The compute pass already did the blend, once per vertex per frame rather
        // than once per vertex per draw. It wrote one copy of the mesh per
        // instance, so the index carries the instance as well as the vertex.
        SkinnedVertex skinned = draw.posed[iid * draw.skin_stride + vid];
        position = skinned.position;
        normal = skinned.normal;
    }

    float4 world = mul(instance.model, float4(position, 1.0));
    output.sv_position = mul(push.frame[0].view_projection, world);
    output.world = world.xyz;
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

// How much of the light reaches this point: 1 fully lit, 0 fully shadowed.
//
// **The same function, character for character, in `material.slang`** — for the
// reason `srgb_to_linear` and `lambert` are duplicated there, which is that a
// material is a change of *shading* and not a second renderer. A material whose
// body is the default `s.albedo * lambert(s.normal)` has to land in the same
// shadow the built-in shading does, or "no material at all" and "the default
// material" stop being the same picture.
//
// ## The four early exits, and why each one answers "lit"
//
//  - **`params.w <= 0`** — no shadow pass ran this frame, or a script set the
//    intensity to zero. The map is the 1x1 white image and the nine taps below
//    would all answer the same thing; this is the branch that does not pay for
//    them.
//  - **`ndc.z` outside [0, 1]** — the point is nearer the light than the fitted
//    box, or beyond it. Nothing was rendered there to occlude it.
//  - **`uv` outside the map** — the point is off to the side of the fitted box.
//    The sampler clamps to the edge, so **without this test a surface outside the
//    map would inherit the shadow of whatever sits on the nearest edge of it**,
//    smeared out to the horizon. That is the classic failure and it looks like a
//    bug in the geometry rather than in the lookup.
//
// The first is a branch this shader takes on every fragment of every frame that
// has no shadows, and the other three are the boundary of the one map. All four
// answer "lit" because a shadow map only ever knows about occluders it was shown,
// and an unlit default would darken everything it was not shown.
//
// ## The bias is two numbers and they do different jobs
//
// `params.z` moves the *sample point* along the surface normal before projecting
// it, in world units, which is what fixes acne on a surface nearly edge-on to the
// light: the point being asked about is lifted off the surface it is on, so its
// own depth stops competing with the texel that recorded it. It is derived from
// the fitted extent in `render/shadow.c3`, so it scales with the scene and there
// is no world size at which it is the wrong magnitude.
//
// `params.y` moves the *comparison* instead, in ndc depth units, and it is the
// one a script can set. Zero by default: the normal offset does the work, and a
// depth bias large enough to matter on its own is a shadow visibly detached from
// its caster.
float shadow_factor(float3 position, float3 normal)
{
    float4 params = push.frame[0].shadow;
    if (params.w <= 0.0) return 1.0;

    float3 offset = position + normalize(normal) * params.z;
    float4 clip = mul(push.frame[0].light_view_projection, float4(offset, 1.0));
    // The fit is orthographic, so `clip.w` is 1 and this divide is free. Written
    // anyway, because a perspective fit — a spot light — would need it and a
    // divide that was silently missing is a shadow that is subtly in the wrong
    // place rather than an error.
    float3 ndc = clip.xyz / clip.w;
    if (ndc.z < 0.0 || ndc.z > 1.0) return 1.0;

    // ndc to uv, and the y is flipped because `gpu/target.c3`'s negative-height
    // viewport is what the shadow pass rasterises with too. Undoing that here is
    // not optional bookkeeping: get it wrong and every shadow is mirrored about
    // the middle of the map, which on a symmetric scene looks *almost* right.
    float2 uv = float2(0.5 + 0.5 * ndc.x, 0.5 - 0.5 * ndc.y);
    if (uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0) return 1.0;

    // Nine taps a texel apart — the cheapest thing that turns a hard stair-step
    // edge into something that reads as a shadow. `SampleLevel` rather than
    // `Sample`: the map has one level and asking for a derivative-chosen one
    // inside a loop is work for a mip chain that does not exist.
    float reference = ndc.z - params.y;
    float lit = 0.0;
    for (int y = -1; y <= 1; y++)
    {
        for (int x = -1; x <= 1; x++)
        {
            float depth = shadow_map.SampleLevel(uv + float2(x, y) * params.x, 0.0).r;
            lit += reference <= depth ? 1.0 : 0.0;
        }
    }

    return 1.0 - params.w * (1.0 - lit / 9.0);
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
    // **The shadow multiplies the direct term and not the ambient one.** A
    // surface in shadow still gets the ambient floor, which is what keeps a
    // shadowed face readable rather than black — the same argument the floor
    // exists for at all. Multiplying the whole result instead would make
    // `three.light.ambient` mean nothing wherever a shadow fell.
    float lambert = max(dot(normal, normalize(light.xyz)), 0.0) * shadow_factor(input.world, normal);
    float ambient = light.w;

    // The material's alpha times this copy's own, exactly as the rgb above
    // multiplies the two. `mesh.color = [r, g, b, a]` therefore fades one
    // instance out of a thousand sharing a draw call — and does nothing at all
    // unless the material was built transparent, because an opaque pipeline
    // discards this channel. It read a hardcoded `1.0` until blending existed.
    return float4(albedo * (ambient + (1.0 - ambient) * lambert), draw.base_color.a * input.color.a);
}
