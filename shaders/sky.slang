// three.c3 sky — the image behind the scene, and the thing that makes a metal
// look like metal.
//
// **Not a template.** Unlike `material.slang` and `post.slang` there are no
// marker lines and no assembler: nothing a script writes reaches this file, so
// it is compiled as it stands through the same `PipelineCache.acquire` the mesh
// shader goes through. That is the whole reason it is its own file rather than a
// branch in `mesh.slang` — a sky has no instances, no draw record, no geometry
// pointers and no material, and every one of those would have had to be given a
// meaningless value to reuse that contract.
//
// ## Three vertices and no geometry
//
// The oldest trick there is: one oversized triangle covering the viewport, so
// the pixels are visited once and there is no seam down a screen-space diagonal
// the way a two-triangle quad has. `post.slang`'s vertex stage is the same three
// vertices; what differs is the depth they are placed at.
//
// **z = 1, which is the far plane, and depth writes are off.** So the sky is
// behind everything by construction rather than by being drawn first and hoping.
// It is still drawn first — `MeshPass.record_sky` has why — and the depth test
// is what keeps it there rather than the order.
//
// ## The direction through a pixel
//
// A sky is a function of *where you are looking*, not of where you are, so the
// only thing this needs per pixel is a world-space ray. The camera's
// view-projection maps a world position to clip space; its inverse maps a clip
// position back, and two clip positions at the same xy and different z name two
// points on the ray through that pixel. Subtracting them is the direction, and
// the camera's own position never enters it.
//
// The clip xy comes off the vertex stage as a varying rather than being rebuilt
// from `SV_Position` and the viewport. That is not a shortcut, it is the only
// version that is right: `set_full_viewport` renders with a flipped viewport, so
// the pixel a clip position lands on is not the pixel a naive
// `sv_position.xy / extent` would compute, and a sky reconstructed that way is
// upside down in the main pass and the right way up in a bake.
//
// ## Equirectangular, not a cube
//
// One 2D image, latitude down and longitude across — the projection every HDRI
// on the internet ships in, and the one `three.texture()` can already load with
// no new image type, no `VK_IMAGE_VIEW_TYPE_CUBE`, no six-face upload path and
// no second thing for a `Texture` to be. A cubemap samples marginally faster and
// has no pole distortion; it also needs all of the above, and the whole of what
// it would buy is available later without changing a line a script writes.
//
// The seam at longitude ±π is where `atan2` wraps, and the sampler crosses it by
// wrapping in u — which is why the image wants `REPEAT` in u and is why nothing
// here clamps. The poles are a single texel stretched across the top and bottom
// rows and always will be; that is equirectangular's own defect, not this one's.

struct SkyPush
{
    // The camera's inverse view-projection. The whole reason this is a push
    // constant rather than a read of the frame block: the sky draws before any
    // of the frame's buffers are bound and needs exactly one matrix out of it.
    float4x4 inverse_view_projection;
    //   x  intensity — what the sampled colour is multiplied by. `three.c3`
    //      renders into an `_SRGB` attachment, so this is a linear multiplier on
    //      a value the sampler already decoded.
    //   y  rotation about world Y, in radians. A sky is the one texture whose
    //      orientation somebody always wants to nudge, and rotating it here is
    //      free where rotating the image is a re-upload.
    //   zw unused.
    float4 params;
};
[vk_push_constant] const SkyPush push;

// The image, always bound. There is no draw at all when a scene has no sky —
// `MeshPass.record_sky` returns before recording anything — so unlike every
// other sampler in this project there is no white 1x1 standing in for an absent
// one, and no need for one.
[vk::binding(0, 0)] Sampler2D sky_map;

struct VertexOutput
{
    float4 sv_position : SV_Position;
    // The vertex's own clip xy, carried rather than recomputed — see the header.
    float2 clip : TEXCOORD0;
};

[shader("vertex")]
VertexOutput vertexMain(uint vid : SV_VertexID)
{
    float2 uv = float2(float((vid << 1) & 2), float(vid & 2));
    float2 clip = uv * 2.0 - 1.0;

    VertexOutput output;
    output.clip = clip;
    // z = 1.0 is the far plane under Vulkan's 0..1 depth range, and the pipeline
    // compares LESS_OR_EQUAL against a buffer cleared to 1.0 — so the sky passes
    // where nothing has been drawn and fails where anything has.
    output.sv_position = float4(clip, 1.0, 1.0);
    return output;
}

// A world direction to a texel of an equirectangular image.
//
// u is the longitude, `atan2(x, z)` mapped to 0..1 with the seam at ±π behind
// the origin of the mapping; v is the latitude, `acos(y)` mapped from 0 at the
// zenith to 1 at the nadir, which is the order an image file's rows are in.
float2 equirect_uv(float3 direction)
{
    const float PI = 3.14159265358979;
    float u = atan2(direction.x, -direction.z) / (2.0 * PI) + 0.5;
    float v = acos(clamp(direction.y, -1.0, 1.0)) / PI;
    return float2(u, v);
}

[shader("fragment")]
float4 fragmentMain(VertexOutput input) : SV_Target
{
    // Two points on the ray through this pixel, un-projected from the same clip
    // xy at the near and far planes. Their difference is the direction; the
    // perspective divide has to happen before the subtraction, because the two
    // w's are different and subtracting before dividing is a different ray.
    float4 near = mul(push.inverse_view_projection, float4(input.clip, 0.0, 1.0));
    float4 far = mul(push.inverse_view_projection, float4(input.clip, 1.0, 1.0));
    float3 direction = normalize(far.xyz / far.w - near.xyz / near.w);

    // The rotation is applied to the *look* direction rather than to the uv, so
    // it is a rotation of the world around the camera and not a slide of the
    // image across it — the two differ everywhere except the equator.
    float angle = push.params.y;
    float s = sin(angle);
    float c = cos(angle);
    direction = float3(c * direction.x - s * direction.z, direction.y, s * direction.x + c * direction.z);

    float3 color = sky_map.Sample(equirect_uv(direction)).rgb * push.params.x;
    return float4(color, 1.0);
}
