// three.c3 shared surface maths.
//
// **This is not a shader and nothing compiles it on its own.** It is spliced
// into every template carrying a `//@shared` line — `mesh.slang` and
// `material.slang` today — by `shader_source` in `src/shader/load.c3`, which
// puts a `#line` back afterwards so a diagnostic in the rest of the template
// still names the line the file has.
//
// **What belongs here is what both files would otherwise carry twice.** The GGX
// block below it in each — `lambert`, `specular_light`, `environment_light` and
// the two functions they lean on — is duplicated character for character today
// and is the next thing that should move; it did not move with this because the
// two copies differ by the `#ifdef THREE_BAKE` branches material.slang wraps
// them in, and unifying that is a change to the bake as well as to the shading.
//
// What it may not touch: `Surface`, which only `material.slang` declares. A
// function here takes the values apart rather than the struct, and the material
// template wraps it back up — which is also why `mesh.slang` can call it at all,
// since a mesh has no `Surface` and never will.

// A tangent-space normal map applied to a surface that carries no tangents.
//
// **The meshes here have positions, normals and uvs and nothing else.** There is
// no `TANGENT` stream, neither shader has anywhere to put one, and a generated
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
// Two things it cannot do, both inherited from having no baked tangents:
// mirrored uv islands come out mirrored rather than flipped, because a
// derivative cannot see the seam a tangent would have recorded; and a face with
// degenerate uvs has no frame at all, which is the interpolated normal returned
// unchanged rather than a NaN.
//
// **Fragment stage only.** `ddx`/`ddy` do not exist in a vertex shader, so
// calling this from a `vertex:` body is a compile error rather than a wrong
// picture.
float3 mapped_normal_frame(float3 normal, float3 position, float2 uv, float3 texel)
{
    float3 n = normalize(normal);

    float3 dp_dx = ddx(position);
    float3 dp_dy = ddy(position);
    float2 duv_dx = ddx(uv);
    float2 duv_dy = ddy(uv);

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
