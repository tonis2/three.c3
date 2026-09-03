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

// One copy's own uv, before the material's repeat and offset — `plan.md` §27.
//
// **The eight symmetries of the square, and deliberately not a free rotation.**
// A quarter turn, a mirror and a slide are the transforms that leave a unit
// square a unit square, so whatever band `material.repeat` then maps into is
// still the band it was: a trim sheet strip survives all eight of these and
// would walk straight out of itself under a rotation of 37 degrees. A body that
// wants a free rotation has `s.variant` and a table of its own and is not
// giving anything up.
//
// **Applied in the vertex stage by both templates**, which is exact rather than
// approximate: every operation here is affine in uv, and an affine map commutes
// with the linear interpolation the rasteriser does, so per-vertex and
// per-pixel are the same picture and the per-vertex one is free.
//
// `row` is one entry of `Draw.uv_variants`: xy slides, z is quarter turns about
// the middle of the face, w is 1 to mirror u, 2 to mirror v, 3 for both. The
// last two are small integers carried as floats because the row is a `float4`
// on both sides of the wire — the alternative is a second array of a second
// type for four bits.
float2 variant_uv(float2 uv, float4 row)
{
    // About (0.5, 0.5) and not about the origin: a face's uv is a unit square
    // and turning it about its corner puts it in the next square along, which is
    // a different strip of a sheet rather than a different orientation of this
    // one.
    uint turns = ((uint)row.z) & 3u;
    if (turns == 1u) uv = float2(uv.y, 1.0 - uv.x);
    else if (turns == 2u) uv = float2(1.0 - uv.x, 1.0 - uv.y);
    else if (turns == 3u) uv = float2(1.0 - uv.y, uv.x);

    uint flip = (uint)row.w;
    if ((flip & 1u) != 0u) uv.x = 1.0 - uv.x;
    if ((flip & 2u) != 0u) uv.y = 1.0 - uv.y;

    // Last, so a slide is in the mesh's own uv units whatever was done to it
    // above — one whole face per unit, which `material.repeat` then scales into
    // however many tiles that is.
    return uv + row.xy;
}

// A stable hash of a lattice cell, for the tile offsets below. Two numbers out
// because a tile's offset is a point in the image, not a scalar.
float2 hash_cell(float2 p)
{
    float2 q = float2(dot(p, float2(127.1, 311.7)), dot(p, float2(269.5, 183.3)));
    return frac(sin(q) * 43758.5453);
}

// The three corners of the triangular lattice cell a uv falls in, and how much
// of each it is — barycentric, so the three weights sum to exactly 1.
//
// Skewed rather than square: a square lattice blends four tiles and its seams
// line up into a visible grid, which is the thing being got rid of. A triangular
// one blends three and its seams meet at 120 degrees, which the eye does not
// assemble into anything.
void triangle_cell(
    float2 uv,
    out float3 weights,
    out float2 corner_a,
    out float2 corner_b,
    out float2 corner_c
)
{
    // 2 * sqrt(3): the cell size, in the uv the caller already tiled. A few
    // cells per repeat of the image is what breaks the repeat without blending
    // so much of the image together that it turns to soup.
    float2 grid = uv * 3.4641016;

    const float2x2 TO_SKEWED = float2x2(1.0, 0.0, -0.57735027, 1.15470054);
    float2 skewed = mul(TO_SKEWED, grid);

    float2 base = floor(skewed);
    float3 part = float3(frac(skewed), 0.0);
    part.z = 1.0 - part.x - part.y;

    // Which of the two triangles of the skewed cell this is, and the corners
    // wind the same way either side so the weights stay a partition of unity
    // across the diagonal.
    if (part.z > 0.0)
    {
        weights = float3(part.z, part.y, part.x);
        corner_a = base;
        corner_b = base + float2(0.0, 1.0);
        corner_c = base + float2(1.0, 0.0);
    }
    else
    {
        weights = float3(-part.z, 1.0 - part.y, 1.0 - part.x);
        corner_a = base + float2(1.0, 1.0);
        corner_b = base + float2(1.0, 0.0);
        corner_c = base + float2(0.0, 1.0);
    }
}

// One texture, sampled so that it stops repeating — `plan.md` §27.
//
// Three taps of the same image at three per-cell random offsets, blended by the
// barycentric weight of a triangular lattice over the uv. Two neighbouring
// repeats of the image read different parts of it, so the eye has no period to
// find, and no second image and no authoring is involved.
//
// **`SampleGrad` and not `Sample`, and this is the whole of whether it works.**
// The offsets are per cell and jump at every cell boundary, so the derivatives
// the hardware would compute for itself are enormous exactly along the seams —
// which selects the smallest mip there and draws a blurred line around every
// cell, a cure more visible than the disease. The gradients handed in are the
// *un-jittered* ones, which is what the surface actually has.
//
// **What it costs, beyond the three taps.** The blend is linear, so where three
// tiles overlap their contrast is averaged down and the surface goes slightly
// flat; the variance-preserving version of this needs a histogram transform of
// the image built ahead of time, which is a build step and not a sampler. And it
// is only for a texture with no structure in it — run it over brick and the
// courses cross each other. Nor for a material that windows into an atlas: the
// offsets go on after `uv_transform`, so a trim sheet's strip is left behind
// entirely. Both are why it is a property of a material rather than something
// the renderer does for you.
//
// A flat image comes back exactly as it was, whatever the offsets do, because
// the weights sum to one. That is the property the test pins.
float4 stochastic_sample(Sampler2D image, float2 uv)
{
    float3 weights;
    float2 a;
    float2 b;
    float2 c;
    triangle_cell(uv, weights, a, b, c);

    float2 dx = ddx(uv);
    float2 dy = ddy(uv);

    return weights.x * image.SampleGrad(uv + hash_cell(a), dx, dy)
         + weights.y * image.SampleGrad(uv + hash_cell(b), dx, dy)
         + weights.z * image.SampleGrad(uv + hash_cell(c), dx, dy);
}
