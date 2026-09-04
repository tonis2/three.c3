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

// ---------------------------------------------------------------------------
// Triplanar
//
// One image projected along the three world axes and blended by which way the
// surface faces — `plan.md` §27. **A projection rather than an unwrap**, which is
// what a rock, a cliff, a merged terrain and a `ConvexGeometry` hull all have:
// `scene/convex.c3` already says a hull's uv is "the same thing in the shader",
// and half the meshes in an imported blockout have no TEXCOORD_0 at all.
//
// Three taps per image and three per map, which is what it costs. It is also the
// mapping that gives a kit one texel density: a node scaled 2.6 by 2.7 by 12.6
// carrying Blender's default cube projection shows the same image five times
// denser one way than the other, and nothing about the uv can fix that.
//
// **Fragment stage only.** The gradients are `ddx`/`ddy`, exactly as
// `mapped_normal` and `stochastic_sample` are.
// ---------------------------------------------------------------------------

// How much of each projection this surface takes, summing to 1.
//
// `sharpness` is how fast one projection gives way to the next: 1 is a long soft
// crossfade that ghosts the other two over everything, and 6 to 8 is a seam a few
// degrees wide, which is what looks like a surface rather than like three of them.
float3 triplanar_weights(float3 normal, float sharpness)
{
    float3 w = pow(abs(normalize(normal)), sharpness);
    return w / max(w.x + w.y + w.z, 1e-5);
}

// One tap of one projection, windowed into a band of a sheet.
//
// `band` is `(height, offset)` in v — one strip of a trim sheet — and
// `(1, 0)` is the whole image, which is the case with no sheet in it.
//
// **`SampleGrad` and the unwrapped gradients, and this is the whole of whether a
// window works.** `frac` jumps by a whole image at every tile boundary, so the
// derivatives the hardware computes for itself are the width of the picture
// exactly along the seams — which selects the smallest mip there and draws a
// blurred line along every tile boundary on every surface in the scene. The
// gradients handed to the sampler are the *continuous* ones, scaled into the
// band, which is what the surface actually has. `stochastic_sample` above does
// the same thing for the same reason.
//
// The `frac` on u is not optional either, even for a whole image: it costs
// nothing where the sampler already repeats, and it is what makes the v window
// mean a band rather than a stripe of one row of tiles.
float4 triplanar_tap(Sampler2D image, float2 uv, float2 band)
{
    float2 scale = float2(1.0, band.x);
    float2 dx = ddx(uv) * scale;
    float2 dy = ddy(uv) * scale;
    return image.SampleGrad(float2(frac(uv.x), band.y + frac(uv.y) * band.x), dx, dy);
}

// The three projections of a world position, at `scale` repeats of the image per
// metre. Which pair of axes each one takes is the usual convention and is the
// one a normal map's Whiteout blend below is written against.
void triplanar_uv(float3 position, float scale, out float2 uv_x, out float2 uv_y, out float2 uv_z)
{
    uv_x = float2(position.z, position.y) * scale;
    uv_y = float2(position.x, position.z) * scale;
    uv_z = float2(position.x, position.y) * scale;
}

// One image, projected three ways and blended — a colour, an ORM, a mask,
// anything whose channels are values rather than directions.
float4 triplanar_sample(
    Sampler2D image, float3 position, float3 normal, float scale, float sharpness, float2 band
)
{
    float3 w = triplanar_weights(normal, sharpness);
    float2 ux;
    float2 uy;
    float2 uz;
    triplanar_uv(position, scale, ux, uy, uz);

    return triplanar_tap(image, ux, band) * w.x
         + triplanar_tap(image, uy, band) * w.y
         + triplanar_tap(image, uz, band) * w.z;
}

// The whole image rather than a band of one, which is every material that is not
// wearing a sheet.
float4 triplanar_sample(Sampler2D image, float3 position, float3 normal, float scale, float sharpness)
{
    return triplanar_sample(image, position, normal, scale, sharpness, float2(1.0, 0.0));
}

// A tangent-space normal map, projected the same three ways and blended
// **Whiteout**.
//
// Each projection hands back a normal in *its own* tangent frame, and averaging
// the three as though they were world vectors flattens every surface that faces
// two ways at once — which is every edge, every corner and every rock. Whiteout
// adds the geometric normal into each projection's xy before the swizzle, so a
// projection that disagrees with the surface loses instead of washing it out.
//
// The map has to be loaded `LinearSRGBColorSpace`, for `mapped_normal`'s reason.
float3 triplanar_normal(
    Sampler2D image, float3 position, float3 normal, float scale, float sharpness, float2 band
)
{
    float3 n = normalize(normal);
    float3 w = triplanar_weights(n, sharpness);
    float2 ux;
    float2 uy;
    float2 uz;
    triplanar_uv(position, scale, ux, uy, uz);

    float3 tx = triplanar_tap(image, ux, band).rgb * 2.0 - 1.0;
    float3 ty = triplanar_tap(image, uy, band).rgb * 2.0 - 1.0;
    float3 tz = triplanar_tap(image, uz, band).rgb * 2.0 - 1.0;

    tx = float3(tx.xy + n.zy, abs(tx.z) * n.x);
    ty = float3(ty.xy + n.xz, abs(ty.z) * n.y);
    tz = float3(tz.xy + n.xy, abs(tz.z) * n.z);

    return normalize(tx.zyx * w.x + ty.xzy * w.y + tz.xyz * w.z);
}

// The whole image rather than a band of one.
float3 triplanar_normal(Sampler2D image, float3 position, float3 normal, float scale, float sharpness)
{
    return triplanar_normal(image, position, normal, scale, sharpness, float2(1.0, 0.0));
}

// Which way a light is and how much of it arrives — the one function that knows
// a light may be a *place* rather than a direction.
//
// `packed` is `Light.direction`: xyz and a w that says which kind this is. **w is
// the range in metres, and 0 means directional** — the value every light carried
// before there was another kind, so a scene written against four suns is
// unchanged and nothing had to move in the wire format to make room. Above zero,
// xyz is a world position and w is how far the light reaches.
//
// The falloff is inverse-square with a window on it. Inverse-square is what light
// does and is why `intensity` on a point light reads as **its brightness one
// metre away**; the window is what makes the light end — a pure inverse square
// never reaches zero, so every light in the scene would contribute a little to
// every pixel and there would be nothing to cull against. The fourth power inside
// it keeps the last metre from creasing, which a linear window puts a visible
// ring at.
//
// The distance is floored, because a light standing exactly on a surface is a
// divide by zero and a whole screen of infinity.
float3 light_toward(float4 packed, float3 position, out float reach)
{
    if (packed.w <= 0.0)
    {
        reach = 1.0;
        return normalize(packed.xyz);
    }

    float3 offset = packed.xyz - position;
    float square = max(dot(offset, offset), 1e-4);
    float distance = sqrt(square);

    float edge = saturate(1.0 - pow(distance / packed.w, 4.0));
    reach = edge * edge / square;
    return offset / distance;
}

// ---------------------------------------------------------------------------
// Noise
//
// **Here because every generated material was carrying its own copy.** A hash, a
// value noise, an fbm and a worley is 120 lines before the first material, and
// they were the same 120 lines in every example in this project and in every body
// written outside it. The tiling ones are the reason this is worth doing rather
// than merely tidy: a period that does not divide the image is a seam nothing
// reports, and each octave's period has to scale with its frequency or the seam
// arrives one octave in.
//
// `three.hash`, `three.noise2` and `three.fbm2` are the JavaScript side of the
// same idea — for a script *baking* a texture rather than shading one. They are a
// different implementation and the patterns do not match texel for texel; what
// matches is the vocabulary.
// ---------------------------------------------------------------------------

// The mixer everything below is built on: two words in, two words out, and no
// `sin` anywhere in it.
//
// **A `sin`-based hash is what a body writes when it has none of these**, and it
// is the one that fails quietly: `frac(sin(x) * 43758.5453)` leans on the low bits
// of a transcendental, which every driver is entitled to compute a little
// differently and which collapses into bands once the coordinate is large enough
// that `sin` loses its own precision — a floor that shows a grid at the far end of
// a level and not at the near one. Integer mixing has neither problem.
uint2 hash_words(uint2 v)
{
    v = v * 1664525u + 1013904223u;
    v.x += v.y * 1664525u;
    v.y += v.x * 1664525u;
    v ^= v >> 16u;
    v.x += v.y * 1664525u;
    v.y += v.x * 1664525u;
    v ^= v >> 16u;
    return v;
}

// 0..1 from a word.
float unit_float(uint h)
{
    return (float)h * (1.0 / 4294967296.0);
}

// A lattice cell, hashed as integers. Internal, and integers on purpose: this is
// what a wrap is applied to, and a cell wrapped in floating point would have to
// come back to *exactly* the coordinate it started from for the two edges of a
// tiling texture to meet.
float cell_hash(int2 cell)
{
    return unit_float(hash_words(uint2(cell)).x);
}

// The same cell, two numbers out — a point inside it, for the worley below.
float2 cell_hash2(int2 cell)
{
    uint2 h = hash_words(uint2(cell));
    return float2(unit_float(h.x), unit_float(h.y));
}

// One number, hashed by its **bits**: 0.5 and 0.51 are unrelated answers, which is
// what a per-copy or per-vertex seed wants. `hash11(float(v.index))` scatters
// vertices; `hash11(s.origin.x + s.origin.z * 31.0)` picks a number for a copy.
float hash11(float x)
{
    return unit_float(hash_words(uint2(asuint(x), 0x9E3779B9u)).x);
}

// Two numbers in, one out, hashed by their bits. `hash21(s.origin.xz)` is a
// number per copy that two copies in two places disagree about.
float hash21(float2 p)
{
    return unit_float(hash_words(uint2(asuint(p.x), asuint(p.y))).x);
}

// Two in, two out — a point, an offset, a direction to pick.
float2 hash22(float2 p)
{
    uint2 h = hash_words(uint2(asuint(p.x), asuint(p.y)));
    return float2(unit_float(h.x), unit_float(h.y));
}

// Which cell, once a period has been applied. A component of 0 does not wrap,
// which is what a strip wants: a trim sheet band tiles along u and is one band
// tall, so the v axis has no period to speak of.
int2 wrap_cell(int2 cell, float2 period)
{
    int2 p = int2(period);
    if (p.x > 0) cell.x = ((cell.x % p.x) + p.x) % p.x;
    if (p.y > 0) cell.y = ((cell.y % p.y) + p.y) % p.y;
    return cell;
}

// Smooth value noise on a unit lattice, 0..1 — one feature per unit of p, and the
// verb behind every generated rock face, bark, dirt and cloud.
//
// `period` wraps the lattice, and **that is what makes a texture tile**: pass the
// number of cells across the image and its left edge meets its right. It has to
// be a whole number of cells, and a period that does not divide the image is a
// seam nothing reports. 0 on an axis does not wrap it.
float noise2(float2 p, float2 period)
{
    int2 i = int2(floor(p));
    float2 f = frac(p);
    float2 w = f * f * (3.0 - 2.0 * f);

    int2 a = wrap_cell(i, period);
    int2 b = wrap_cell(i + int2(1, 0), period);
    int2 c = wrap_cell(i + int2(0, 1), period);
    int2 d = wrap_cell(i + int2(1, 1), period);

    return lerp(
        lerp(cell_hash(a), cell_hash(b), w.x),
        lerp(cell_hash(c), cell_hash(d), w.x),
        w.y
    );
}

// The same, not tiling — for a surface whose uv does not have to meet itself.
float noise2(float2 p)
{
    return noise2(p, float2(0.0, 0.0));
}

// Fractal Brownian motion: `octaves` layers of `noise2`, each twice as fine and
// half as strong, normalized back to 0..1.
//
// **The period doubles with the frequency**, which is the one line that is wrong
// in every hand-written tiling fbm: an octave whose period stayed where the first
// one left it wraps at the wrong place, and the result is a texture that tiles
// except for one band of detail that does not.
float fbm2(float2 p, float2 period, int octaves)
{
    float sum = 0.0;
    float total = 0.0;
    float amplitude = 1.0;
    float2 at = p;
    float2 per = period;
    for (int i = 0; i < octaves; i++)
    {
        sum += amplitude * noise2(at, per);
        total += amplitude;
        amplitude *= 0.5;
        at *= 2.0;
        per *= 2.0;
    }
    return total > 0.0 ? sum / total : 0.0;
}

// The same, not tiling.
float fbm2(float2 p, int octaves)
{
    return fbm2(p, float2(0.0, 0.0), octaves);
}

// Distance to the nearest of one feature point per cell — pebbles, cracked mud,
// scales, cell walls, the shape a stone floor is made of.
//
// **0 at a feature point** and climbing towards 1 at the places farthest from all
// of them, so `1.0 - worley2(p)` is the blob and `worley2(p)` is the mortar.
// Clamped at 1 rather than left to run past it: with one point per cell the
// farthest a pixel can be is about 1.5 cells, and a value nobody can bound is a
// value every caller has to bound for itself.
//
// `period` wraps it, on the same terms `noise2` wraps: whole cells, and 0 on an
// axis leaves that axis alone.
float worley2(float2 p, float2 period)
{
    int2 base = int2(floor(p));
    float2 f = frac(p);
    float nearest = 1.0;

    for (int y = -1; y <= 1; y++)
    {
        for (int x = -1; x <= 1; x++)
        {
            int2 over = int2(x, y);
            // The neighbour is wrapped for the *hash* and not for the distance:
            // the point still lives in the cell next door, it is merely the same
            // point the cell on the far side of the image has.
            float2 feature = float2(over) + cell_hash2(wrap_cell(base + over, period));
            nearest = min(nearest, length(feature - f));
        }
    }
    return min(nearest, 1.0);
}

// The same, not tiling.
float worley2(float2 p)
{
    return worley2(p, float2(0.0, 0.0));
}
