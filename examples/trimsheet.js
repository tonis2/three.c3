// A trim sheet baked out of a shader, and a scene wearing it.
//
//   ./build/three --script examples/trimsheet.js --headless --frames 1
//

const SIZE = 1024; // the sheet, square
const STRIPS = 8; // bands stacked down v
const ASPECT = STRIPS; // a strip is SIZE x SIZE/STRIPS texels, so 8:1
const RELIEF = 22; // the full 0..1 height range, in texels — what the slope is scaled by

// The layout, and the one thing both halves of this file have to agree about.
// A sheet is a descriptor before it is a texture: without this the generator
// writes a picture and the scene has no way to ask for the third band of it.
//
// `rough` and `metal` are spliced into the shader as its own constants, so the
// numbers the scene expects to read back are the numbers the body wrote.
const LAYOUT = [
	{ name: 'planks', rough: 0.72, metal: 0.0 },
	{ name: 'rivets', rough: 0.34, metal: 1.0 },
	{ name: 'brick', rough: 0.88, metal: 0.0 },
	{ name: 'panel', rough: 0.45, metal: 0.0 },
	{ name: 'molding', rough: 0.38, metal: 0.0 },
	{ name: 'tiles', rough: 0.22, metal: 0.0 },
	{ name: 'concrete', rough: 0.95, metal: 0.0 },
	{ name: 'gold', rough: 0.25, metal: 1.0 },
];
const strip = (name) => LAYOUT.findIndex((s) => s.name === name);

// The calibration bake: a height field that is a sine along u and flat along v,
// so its slope — and therefore every texel of its normal map — has a closed form.
// `plan.md` §25 asks for exactly this, and it is the only part of a procedural
// material whose correctness is a number rather than an opinion.
const PROBE_WAVES = 8;
const PROBE_AMPLITUDE = 0.5;

// ---------------------------------------------------------------------------
// The generator
// ---------------------------------------------------------------------------

const SHEET = `
// The layout, spliced in from the JavaScript above so there is one copy of it.
static const float ASPECT = ${ASPECT}.0;
static const float STRIP_ROUGH[${STRIPS}] = { ${LAYOUT.map((s) => s.rough.toFixed(3)).join(', ')} };
static const float STRIP_METAL[${STRIPS}] = { ${LAYOUT.map((s) => s.metal.toFixed(3)).join(', ')} };

// One conversion, used for two opposite reasons. On a colour it is authoring:
// the numbers below are written the way a picker shows them and this puts them
// in the linear space the body works in. On a normal or a roughness it is the
// pre-encode that cancels the target's sRGB write, so the byte in the PNG is the
// value that was meant.
float to_linear(float c)
{
    return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4);
}

float3 data(float3 c)
{
    return float3(to_linear(c.r), to_linear(c.g), to_linear(c.b));
}

float hash21(float2 p)
{
    p = frac(p * float2(127.1, 311.7));
    p += dot(p, p + 34.23);
    return frac(p.x * p.y);
}

float wrap(float x, float period)
{
    return x - floor(x / period) * period;
}

// Value noise that repeats in x, because a strip has to tile along u and a
// lattice that does not wrap puts a visible seam at the end of every wall.
float pnoise(float2 p, float period)
{
    float2 i = floor(p);
    float2 f = frac(p);
    float2 w = f * f * (3.0 - 2.0 * f);
    float x0 = wrap(i.x, period);
    float x1 = wrap(i.x + 1.0, period);
    float a = hash21(float2(x0, i.y));
    float b = hash21(float2(x1, i.y));
    float c = hash21(float2(x0, i.y + 1.0));
    float d = hash21(float2(x1, i.y + 1.0));
    return lerp(lerp(a, b, w.x), lerp(c, d, w.x), w.y);
}

float pfbm(float2 p, float period, int octaves)
{
    float sum = 0.0;
    float amp = 0.5;
    float per = period;
    for (int i = 0; i < octaves; i++)
    {
        sum += amp * pnoise(p, per);
        p *= 2.0;
        per *= 2.0;
        amp *= 0.5;
    }
    return sum;
}

// What one texel of the sheet is: a height, a colour, and the two numbers the
// ORM carries. Height is the only one the normal reads, which is why the four
// travel together — the neighbours a central difference needs are evaluations of
// this same function and not of a second one that could drift from it.
struct Trim
{
    float h;
    float3 albedo;
    float rough;
    float metal;
};

// Boards running along u, three across the strip, with the gap between them cut
// into the height rather than painted into the colour.
Trim planks(float2 q)
{
    float rows = 3.0;
    float y = q.y * rows;
    float board = floor(y);
    float by = frac(y);
    float gap = smoothstep(0.0, 0.05, by) * smoothstep(0.0, 0.05, 1.0 - by);
    float grain = pfbm(float2(q.x * 6.0, board * 17.0 + by * 3.0), 48.0, 4);
    float rings = frac(grain * 7.0);
    float tone = hash21(float2(board, 3.0));

    Trim o;
    o.h = 0.30 + gap * 0.55 - grain * 0.10;
    o.albedo = lerp(float3(0.30, 0.19, 0.11), float3(0.58, 0.40, 0.23), saturate(grain * 1.4));
    o.albedo *= lerp(0.88, 1.06, rings) * lerp(0.85, 1.05, tone);
    o.albedo = data(o.albedo) * lerp(0.30, 1.0, gap);
    o.rough = STRIP_ROUGH[0] + (0.5 - grain) * 0.14;
    o.metal = 0.0;
    return o;
}

// A plate with a row of domed rivets down the middle and a chamfer at each edge.
Trim rivets(float2 q)
{
    // Both axes in the same units, so a circle here is a circle in texels: the
    // cell is half a q-unit wide and a whole one tall, and x carries the /2 for it.
    float2 g = float2((frac(q.x * 2.0) - 0.5) * 0.5, q.y - 0.5) * 2.0;
    float d = length(g);
    float dome = sqrt(saturate(1.0 - saturate(d / 0.34) * saturate(d / 0.34)));
    float edge = smoothstep(0.0, 0.09, q.y) * smoothstep(0.0, 0.09, 1.0 - q.y);
    float scuff = pfbm(float2(q.x * 20.0, q.y * 5.0), 160.0, 3);

    Trim o;
    o.h = 0.35 * edge + dome * 0.45 - scuff * 0.05;
    // The rivet is a shape in the height and it is also a shade in the colour: a
    // map that carried it only in the normal disappears the moment a light is
    // straight on.
    float3 steel = float3(0.44, 0.46, 0.50) * lerp(0.8, 1.1, scuff);
    o.albedo = data(steel * lerp(1.0, 1.16, dome) * lerp(0.55, 1.0, edge));
    o.rough = STRIP_ROUGH[1] + scuff * 0.25 + (1.0 - edge) * 0.2;
    o.metal = STRIP_METAL[1] * lerp(0.75, 1.0, edge);
    return o;
}

// Running bond: eight bricks across, four courses down, every other course
// shifted half a brick. The column index wraps so the colour does not seam.
Trim brick(float2 q)
{
    float rows = 4.0;
    float y = q.y * rows;
    float course = floor(y);
    float ry = frac(y);
    float x = q.x + fmod(course, 2.0) * 0.5;
    float col = wrap(floor(x), ASPECT);
    float rx = frac(x);

    float mortar_x = 0.05;
    float mortar_y = mortar_x * rows;
    float face = smoothstep(0.0, mortar_x, rx) * smoothstep(0.0, mortar_x, 1.0 - rx)
               * smoothstep(0.0, mortar_y, ry) * smoothstep(0.0, mortar_y, 1.0 - ry);

    float tone = hash21(float2(col, course));
    float grit = pfbm(float2(q.x * 24.0, q.y * 24.0), 192.0, 4);

    Trim o;
    o.h = 0.28 + face * 0.55 + (grit - 0.5) * 0.06 * face;
    float3 clay = lerp(float3(0.42, 0.20, 0.15), float3(0.62, 0.33, 0.24), tone);
    clay *= lerp(0.85, 1.1, grit);
    o.albedo = data(lerp(float3(0.55, 0.53, 0.50) * lerp(0.9, 1.0, grit), clay, face));
    o.rough = lerp(0.96, STRIP_ROUGH[2] + (grit - 0.5) * 0.1, face);
    o.metal = 0.0;
    return o;
}

// Four recessed panels with a beveled border — the shape a door or a wainscot is
// made of, and the one strip whose height is a distance field rather than noise.
Trim panel(float2 q)
{
    float sections = 4.0;
    float sx = frac(q.x * sections / ASPECT);
    float dx = min(sx, 1.0 - sx) * (ASPECT / sections);
    float dy = min(q.y, 1.0 - q.y);
    float d = min(dx, dy);
    float bevel = smoothstep(0.05, 0.17, d);
    float dirt = pfbm(float2(q.x * 12.0, q.y * 12.0), 96.0, 4);

    Trim o;
    o.h = 0.85 - bevel * 0.40;
    float3 paint = float3(0.58, 0.60, 0.63) * lerp(0.92, 1.05, dirt);
    o.albedo = data(paint * lerp(0.78, 1.0, bevel));
    o.rough = STRIP_ROUGH[3] + (1.0 - bevel) * 0.18 + (dirt - 0.5) * 0.08;
    o.metal = 0.0;
    return o;
}

// A molding profile: it varies across the strip and not along it, which is what
// makes it a length of trim rather than a pattern.
Trim molding(float2 q)
{
    float t = q.y;
    float k = saturate((t - 0.30) / 0.24);
    float roll = sqrt(saturate(1.0 - (k * 2.0 - 1.0) * (k * 2.0 - 1.0)));
    float fillet = smoothstep(0.56, 0.64, t) * (1.0 - smoothstep(0.76, 0.84, t));
    float lip = smoothstep(0.86, 0.91, t);
    float chip = pfbm(float2(q.x * 30.0, q.y * 6.0), 240.0, 3);

    Trim o;
    o.h = 0.20 + roll * 0.55 + fillet * 0.22 + lip * 0.22 - chip * 0.06;
    float3 stone = float3(0.70, 0.68, 0.63) * lerp(0.88, 1.06, chip);
    o.albedo = data(stone * lerp(0.75, 1.0, saturate(o.h * 1.3)));
    o.rough = STRIP_ROUGH[4] + chip * 0.2;
    o.metal = 0.0;
    return o;
}

// Thirty-two square tiles across, four down, each one its own shade and sitting
// its own fraction of a texel proud of the grout.
Trim tiles(float2 q)
{
    float cells = 4.0;
    float2 g = q * cells;
    float2 id = float2(wrap(floor(g.x), ASPECT * cells), floor(g.y));
    float2 f = frac(g);
    float grout = 0.09;
    float face = smoothstep(0.0, grout, f.x) * smoothstep(0.0, grout, 1.0 - f.x)
               * smoothstep(0.0, grout, f.y) * smoothstep(0.0, grout, 1.0 - f.y);
    float tone = hash21(id);

    Trim o;
    o.h = 0.25 + face * (0.55 + (tone - 0.5) * 0.08);
    float3 glaze = lerp(float3(0.16, 0.34, 0.40), float3(0.30, 0.55, 0.58), tone);
    o.albedo = data(lerp(float3(0.48, 0.46, 0.43), glaze, face));
    o.rough = lerp(0.92, STRIP_ROUGH[5] + (tone - 0.5) * 0.06, face);
    o.metal = 0.0;
    return o;
}

// Cast concrete: low-frequency lumps with pits punched out of them.
Trim concrete(float2 q)
{
    float lumps = pfbm(float2(q.x * 8.0, q.y * 8.0), 64.0, 5);
    float fine = pfbm(float2(q.x * 40.0, q.y * 40.0), 320.0, 3);
    float pit = smoothstep(0.60, 0.72, pnoise(float2(q.x * 26.0, q.y * 26.0), 208.0));

    Trim o;
    o.h = 0.62 + (lumps - 0.5) * 0.22 + (fine - 0.5) * 0.05 - pit * 0.40;
    float3 grey = float3(0.52, 0.51, 0.49) * lerp(0.86, 1.08, lumps);
    o.albedo = data(grey * lerp(0.65, 1.0, 1.0 - pit));
    o.rough = STRIP_ROUGH[6] - pit * 0.1;
    o.metal = 0.0;
    return o;
}

// An ornamental band: a chain of raised lozenges between two rails.
Trim gold(float2 q)
{
    float2 g = float2((frac(q.x * 2.0) - 0.5) * 0.5, q.y - 0.5);
    float diamond = abs(g.x) + abs(g.y);
    float boss = 1.0 - smoothstep(0.16, 0.24, diamond);
    float rail = smoothstep(0.30, 0.36, abs(g.y)) * (1.0 - smoothstep(0.42, 0.47, abs(g.y)));
    float wear = pfbm(float2(q.x * 26.0, q.y * 8.0), 208.0, 3);

    Trim o;
    o.h = 0.30 + boss * 0.45 + rail * 0.30 - wear * 0.05;
    float3 metal = lerp(float3(0.62, 0.46, 0.16), float3(0.92, 0.76, 0.36), saturate(boss + rail));
    o.albedo = data(metal * lerp(0.85, 1.06, wear));
    o.rough = STRIP_ROUGH[7] + wear * 0.35 * (1.0 - saturate(boss + rail));
    o.metal = STRIP_METAL[7] * lerp(0.7, 1.0, saturate(boss + rail + 0.4));
    return o;
}

// The sheet, as one function of uv. The strip index comes out of v and the strip
// gets the rest, in a space where one unit of x is one unit of y in texels —
// which is what keeps a rivet round and a tile square.
Trim sheet(float2 uv)
{
    float row = uv.y * ${STRIPS}.0;
    int k = int(clamp(floor(row), 0.0, ${STRIPS}.0 - 1.0));
    float2 q = float2(frac(uv.x) * ${ASPECT}.0, frac(row));

    if (probe > 0.5)
    {
        // The calibration field: a sine along u, flat along v, amplitude and
        // frequency known to the caller. Nothing else about the sheet is in it.
        Trim o;
        o.h = 0.5 + ${PROBE_AMPLITUDE} * sin(6.2831853071795864 * ${PROBE_WAVES}.0 * uv.x);
        o.albedo = float3(0.5, 0.5, 0.5);
        // A ramp each way, so the ORM's own round trip is 1024 known values wide
        // rather than one.
        o.rough = uv.x;
        o.metal = uv.y;
        return o;
    }

    if (k == 0) return planks(q);
    if (k == 1) return rivets(q);
    if (k == 2) return brick(q);
    if (k == 3) return panel(q);
    if (k == 4) return molding(q);
    if (k == 5) return tiles(q);
    if (k == 6) return concrete(q);
    return gold(q);
}

// The normal, differentiated from the height at float precision rather than
// recovered from a stored one. 'relief' is the height range in texels, so the
// two differences and the constant 1.0 are in the same units and the arctangent
// the normalize performs is the real slope of the surface.
float3 surface_normal(float2 uv, float2 texel)
{
    float l = sheet(uv - float2(texel.x, 0.0)).h;
    float r = sheet(uv + float2(texel.x, 0.0)).h;
    float u = sheet(uv - float2(0.0, texel.y)).h;
    float d = sheet(uv + float2(0.0, texel.y)).h;
    return normalize(float3(-(r - l) * 0.5 * relief, -(d - u) * 0.5 * relief, 1.0));
}

// Occlusion by a horizon sweep over the same height function: sixteen taps, and
// each one asks how far above this texel the field gets in that direction.
float occlusion(float2 uv, float2 texel)
{
    float h0 = sheet(uv).h;
    float sum = 0.0;
    for (int i = 0; i < 8; i++)
    {
        float a = 6.2831853071795864 * (float(i) + 0.5) / 8.0;
        float2 dir = float2(cos(a), sin(a));
        for (int j = 1; j <= 2; j++)
        {
            float radius = float(j) * 5.0;
            float rise = (sheet(uv + dir * texel * radius).h - h0) * relief;
            sum += saturate(rise / radius);
        }
    }
    return saturate(1.0 - sum / 16.0 * 1.6);
}

float3 post(Post p)
{
    float2 uv = p.uv;
    float2 texel = 1.0 / p.resolution;

    if (channel < 0.5) return sheet(uv).albedo;

    if (channel < 1.5)
    {
        float3 n = surface_normal(uv, texel);
        return data(n * 0.5 + 0.5);
    }

    Trim s = sheet(uv);
    return data(float3(occlusion(uv, texel), saturate(s.rough), saturate(s.metal)));
}`;

// ---------------------------------------------------------------------------
// The decal
//
// A trim sheet gives a level its surfaces and takes its variety away in the same
// stroke: every wall is the same eight strips. A decal is what puts the variety
// back where the eye actually looks — a crack, a leak, a poster, a scorch — and
// it is the one thing on a wall that is allowed not to tile.
//
// **This is the flat-receiver half of it, and it needs nothing the engine did
// not already have**: a quad a few millimetres proud of the wall, a body that
// draws a crack and `discard`s everywhere else. `plan.md` §27's decal item is the
// other half — `three.DecalGeometry`, which clips the receiver's own triangles
// so a decal can lie across a corner or a curve — and it is not this.
//
// Two things worth reading it for:
//
// - **`s.origin` earns its place.** Every one of these is the same mesh and the
//   same material, so they are one draw call; the body seeds itself from the
//   copy's world origin, so no two of them are the same crack. There is nothing
//   to author and no per-copy channel spent — `color` and `variant` are both
//   still free for something else.
// - **`discard` is the only alpha there is.** A body returns rgb, and how much
//   of the surface shows is the material's opacity times the copy's, both of
//   which are per copy and not per pixel. So the crack's *shape* is a cut and
//   its edge is hard. That is what an alpha-tested decal has always been, and it
//   is why the taper below is in the shape rather than in an alpha ramp.
// ---------------------------------------------------------------------------

const CRACK = `
float hash11(float n)
{
    return frac(sin(n * 78.233) * 43758.5453);
}

float hash21(float2 p)
{
    return frac(sin(dot(p, float2(127.1, 311.7))) * 43758.5453);
}

float vnoise(float2 p)
{
    float2 i = floor(p);
    float2 f = frac(p);
    float2 w = f * f * (3.0 - 2.0 * f);
    return lerp(
        lerp(hash21(i), hash21(i + float2(1.0, 0.0)), w.x),
        lerp(hash21(i + float2(0.0, 1.0)), hash21(i + float2(1.0, 1.0)), w.x),
        w.y
    );
}

float fbm(float2 p)
{
    float sum = 0.0;
    float amp = 0.5;
    for (int i = 0; i < 4; i++)
    {
        sum += amp * vnoise(p);
        p *= 2.0;
        amp *= 0.5;
    }
    return sum;
}

// The scalar field whose level set is the crack, warped so the level set
// branches the way a fracture front does instead of meandering like a river.
float field(float2 p)
{
    p += 0.45 * float2(fbm(p * 1.4 + 3.1), fbm(p * 1.4 - 1.4));
    return fbm(p);
}

// How much of a crack is at this point of the quad, 1 on the fracture and 0 off
// it.
//
// A **level set** and not a drawn line: the crack is where the field crosses its
// own middle, which is what gives it branching, varying width and tapered ends
// without any of the three being authored. Fracture propagates along a front,
// and this is what a front looks like.
//
// **The divide by the gradient is the whole difference between a crack and a
// stain.** Thresholding |field - 0.5| directly makes a line wherever the field
// is steep and a *blob* wherever it is flat, and a warped noise field is flat in
// plenty of places — the first version of this read as splatter. Dividing by the
// local slope turns the value into a distance to the level set, so the line is
// the same width along its whole length however the field is behaving under it.
float crack(float2 uv, float seed, float taper)
{
    float2 p = uv * 2.2 + seed * 31.7;

    const float e = 0.0035;
    float n = field(p);
    float gx = field(p + float2(e, 0.0)) - field(p - float2(e, 0.0));
    float gy = field(p + float2(0.0, e)) - field(p - float2(0.0, e));
    float slope = max(length(float2(gx, gy)) / (2.0 * e), 1e-4);
    float dist = abs(n - 0.5) / slope;

    // Opening and closing along its length, and closing to nothing at the edge
    // of the quad — the taper is in the *width* rather than in the mask, so the
    // crack narrows away instead of being cut off square. That straight cut is
    // the tell that gives away every badly placed decal.
    float width = (0.010 + 0.026 * fbm(p * 2.5 + 11.0)) * taper;
    return 1.0 - smoothstep(width, width * 2.6, dist);
}

float3 shade(Surface s)
{
    // Where this copy stands, hashed — one number, and it is the whole of why
    // these are all different. See plan.md section 27.
    float seed = hash11(s.origin.x * 12.9898 + s.origin.y * 78.233 + s.origin.z * 37.719);

    float2 d = abs(s.uv - 0.5) * 2.0;
    float taper = 1.0 - smoothstep(0.35, 1.0, max(d.x, d.y));
    if (taper <= 0.0) discard;

    float core = crack(s.uv, seed, taper);
    if (core < 0.5) discard;

    // Dark, and lit rather than flat black: a crack is a hole in a surface that
    // is standing in this scene's light, and one that ignored the sun would read
    // as a sticker.
    //
    // The rim is lighter than the core, off the same number the cut was made
    // with — a break in brick has a chipped edge catching the light and a void
    // behind it, and one flat value has neither.
    float depth = smoothstep(0.5, 1.0, core);
    float3 rim = float3(0.16, 0.13, 0.11);
    float3 void_ = float3(0.030, 0.026, 0.024);
    return lerp(rim, void_, depth) * (0.45 + 0.55 * lambert(s.normal));
}`;

// ---------------------------------------------------------------------------
// The run
// ---------------------------------------------------------------------------

// The sheet is square and 1024 a side because LAYOUT says it is, so the render
// size is pinned to it rather than left to whatever `--width` or a window gave.
// A post pass writes exactly the frame, and the frame has to be the sheet. It
// stays pinned afterwards so the scene shot is the same picture whichever run
// took it.
three.setRenderSize(SIZE, SIZE);

// One entry per file the sheet is made of: how it is written, and how it reads
// back. **One table rather than two**, because the shot that writes a normal map
// and the load that reads it linear are the same claim about one file — split in
// two they drift, and a map read back through the wrong colour space is a bug
// with no error message and a soft-looking scene.
//
// `setup` puts the generator in the state the shot wants and `three.screenshot`
// draws and writes it on the next line, so what lands in the file is what the
// entry beside it says. `pass` is the post pass, which exists only while baking.
let pass = null;
const MAPS = [
	{ key: 'color', file: 'build/trim_0.png', what: 'baseColor', linear: false,
		setup: () => { pass.uniforms.channel = 0; pass.uniforms.probe = 0; } },
	{ key: 'normal', file: 'build/trim_1.png', what: 'normal', linear: true,
		setup: () => { pass.uniforms.channel = 1; } },
	{ key: 'orm', file: 'build/trim_2.png', what: 'orm', linear: true,
		setup: () => { pass.uniforms.channel = 2; } },
	{ key: 'probeNormal', file: 'build/trim_3.png', what: 'probeNormal', linear: true,
		setup: () => { pass.uniforms.channel = 1; pass.uniforms.probe = 1; } },
	{ key: 'probeOrm', file: 'build/trim_4.png', what: 'probeOrm', linear: true,
		setup: () => { pass.uniforms.channel = 2; } },
];

// The sixth file, which is the scene rather than part of the sheet, so it is
// written every run and is not something to reuse.
const SCENE_SHOT = 'build/trim_5.png';

// The sheet as five textures, or null if any one of the files is not there yet.
//
// **The load is the check.** There is no `three.exists`, and this wants the
// images on the device anyway — three for the materials and two for the report —
// so `three.texture` throwing on a path with no file behind it answers both
// questions in one call.
//
// All five or none. A half-written sheet is not a sheet: an interrupted run or
// one file deleted by hand would leave the maps from one bake beside probes from
// another, and the report would then be checking a file the scene is not wearing.
// So whatever did load is disposed and the whole thing is baked again.
function readSheet() {
	const loaded = {};
	for (const map of MAPS) {
		try {
			loaded[map.key] = three.texture(map.file, map.linear ? { colorSpace: three.LinearSRGBColorSpace } : null);
		} catch {
			for (const texture of Object.values(loaded)) texture.dispose();
			return null;
		}
	}
	return loaded;
}

// Write all five, in one pass over the table.
//
// The post chain is set up here rather than at the top of the file because
// setting it compiles the generator — three hundred lines of Slang — and a run
// that is reusing the sheet has no use for it. It is taken down again at the end,
// because the scene below is a scene and not a full-frame shader.
function bakeSheet() {
	pass = three.setPost({
		fragment: SHEET,
		uniforms: { channel: 0, relief: RELIEF, probe: 0 },
	});

	for (const map of MAPS) {
		map.setup();
		three.screenshot(map.file);
	}

	three.setPost(null);
	pass = null;
}

// The whole run: read the sheet, bake it if it was not there, wear it, and say
// what is actually in the files.
let maps = readSheet();
const baked = maps === null;
if (baked) {
	bakeSheet();
	maps = readSheet();
}

dress(maps);
three.screenshot(SCENE_SHOT);
report(maps, baked);

// ---------------------------------------------------------------------------
// Wearing it
// ---------------------------------------------------------------------------

// Lay strip `k` across a face once down its height and as many times along its
// length as keeps the texels square. That last part is the whole reason a trim
// sheet is a sheet and not eight textures: one image, one material per band, and
// the density comes out of the geometry rather than out of an artist's guess.
//
// The inset is not optional. A repeat of exactly 1/STRIPS puts the band's last
// texel on the seam and bilinear filtering reaches past it, so the bottom row of
// one strip is the top row of the next. One texel closes that at the top mip and
// not below it — level four spans sixteen — and the real answer is a gutter baked
// into the sheet, which is a change to the generator rather than to this line.
function wearStrip(material, k, width, height) {
	const band = 1 / STRIPS;
	const inset = 1 / SIZE;
	material.repeat = [Math.max(width / (height * ASPECT), 0.02), band - 2 * inset];
	material.offset = [0, k * band + inset];
}

// One material per band, and all three maps are the same two images every time.
//
// `roughness` and `metalness` are 1 because the map multiplies them rather than
// replacing them — glTF's rule, and this renderer's — so a material left at the
// default metalness of 0 multiplies the sheet's metal channel away and the gold
// and the steel come out as painted plastic.
function trimMaterial(maps, k, width, height) {
	const material = new three.MeshLambertMaterial({
		map: maps.color,
		normalMap: maps.normal,
		metalnessRoughnessMap: maps.orm,
		aoMap: maps.orm,
		roughness: 1,
		metalness: 1,
		reflectance: 0.5,
	});
	wearStrip(material, k, width, height);
	return material;
}

// A band of wall: one box, one material, one strip.
function band(parent, maps, name, y, height, width, depth = 0.5) {
	const mesh = new three.Mesh(new three.BoxGeometry(width, height, depth));
	mesh.material = trimMaterial(maps, strip(name), width, height);
	mesh.position.set(0, y + height / 2, 0);
	parent.add(mesh);
	return mesh;
}

// An equirectangular sky, so the metal strips have something to be metal about.
// Rows run bottom to top in a DataTexture, which is why the horizon is built
// from the bottom up here.
function skyTexture() {
	const w = 64;
	const h = 32;
	const bytes = new Uint8Array(w * h * 4);
	for (let y = 0; y < h; y++) {
		const t = y / (h - 1);
		const r = Math.round(255 * (0.42 + 0.46 * t));
		const g = Math.round(255 * (0.46 + 0.46 * t));
		const b = Math.round(255 * (0.50 + 0.42 * t));
		for (let x = 0; x < w; x++) {
			const i = (y * w + x) * 4;
			bytes[i] = r;
			bytes[i + 1] = g;
			bytes[i + 2] = b;
			bytes[i + 3] = 255;
		}
	}
	return new three.DataTexture(bytes, w, h);
}

// The scene, out of the sheet it is handed. It does not load anything: the five
// files were opened by `readSheet` — which is the same call whether they were
// just baked or were already there — so there is one place that says which file
// is read in which colour space, and it is the table.
function dress(maps) {
	const scene = new three.Scene();
	scene.environment = skyTexture();
	scene.background = 0x232a33;
	three.light.set([0.45, 0.75, 0.5], 0.22);
	three.light.intensity = 1.6;
	three.light.shadow = { enabled: true, size: 2048, distance: 26 };

	const floor = new three.Mesh(new three.BoxGeometry(30, 0.4, 22));
	floor.position.y = -0.2;
	floor.color = 0x2a2c30;
	scene.add(floor);

	// The wall, and the argument for the whole thing: six bands, six materials,
	// one 1024² image, and every band at the same texel density because
	// `wearStrip` derives it from the piece rather than being told.
	const wall = new three.Group();
	const W = 14;
	band(wall, maps, 'brick', 0.0, 1.6, W);
	band(wall, maps, 'gold', 1.6, 0.22, W, 0.56);
	band(wall, maps, 'panel', 1.82, 1.5, W);
	band(wall, maps, 'molding', 3.32, 0.3, W, 0.6);
	band(wall, maps, 'planks', 3.62, 1.1, W);
	band(wall, maps, 'rivets', 4.72, 0.28, W, 0.58);
	wall.position.z = -3;
	scene.add(wall);

	// Two pillars, and the honest limit of a trim sheet in three meshes each: a
	// strip runs along u and tiles along u, so a piece taller than the strip is
	// tall gets the strip stretched up it. A column is therefore *built* out of
	// bands the way the wall is — base, shaft, cap — rather than mapped in one
	// go, which is how a kit made against a sheet is cut in the first place.
	//
	// The shaft segments take a slide each as well, so a column is not three
	// copies of one patch of concrete stacked on itself — which is exactly the
	// seam a stacked kit piece shows and the reason this feature exists.
	const shaftGeometry = new three.BoxGeometry(0.7, 1.05, 0.7);
	const shaftMaterial = trimMaterial(maps, strip('concrete'), 0.7, 1.05);
	// Whole faces of slide rather than fractions: the concrete strip is eight
	// faces long at this density, so a slide of three faces is a different part
	// of it and a slide of a tenth is the same part very slightly moved. No
	// turns here — a shaft face is 0.083 by 0.125 of the sheet and not square,
	// so a quarter turn would stretch the grain.
	shaftMaterial.uvVariants = [[0, 0, 0, 0], [3.1, 0, 0, 1], [6.7, 0, 0, 2]];
	const capGeometry = new three.BoxGeometry(0.95, 0.3, 0.95);
	const capMaterial = trimMaterial(maps, strip('molding'), 0.95, 0.3);
	for (const x of [-5.6, 5.6]) {
		for (let i = 0; i < 3; i++) {
			const shaft = new three.Mesh(shaftGeometry);
			shaft.material = shaftMaterial;
			shaft.variant = i;
			shaft.position.set(x, 0.3 + 0.525 + i * 1.05, -1.2);
			scene.add(shaft);
		}
		for (const y of [0.15, 3.6]) {
			const cap = new three.Mesh(capGeometry);
			cap.material = capMaterial;
			cap.position.set(x, y, -1.2);
			scene.add(cap);
		}
	}

	// Crates: one shape, one strip, four copies — still one draw call, and no two
	// of them wearing the same part of the strip.
	//
	// `uvVariants` is the whole of that. A row slides and turns the face's own uv
	// *before* `repeat` maps it into the band, so every one of these is still
	// inside the rivet strip and none of them is the same picture.
	//
	// **A quarter turn, and not just a slide, because of what the strip is.** A
	// cube face here maps to a square of the sheet — `wearStrip` gives it
	// `repeat` 0.125 by 0.125 — so a turn is aspect-preserving and the rivets
	// run a different way on every crate. A slide alone was the first thing
	// written here and it was invisible: the rivets repeat every sixteenth of
	// the sheet, and slides of 0.5 and 0.75 of a face are exactly one and
	// one-and-a-half of those, so two of the four crates were pixel-identical to
	// the other two. The lesson generalises — a slide has to be measured against
	// the *pattern's* period, not against the face.
	const crateGeometry = new three.BoxGeometry(1, 1, 1);
	const crateMaterial = trimMaterial(maps, strip('rivets'), 1, 1);
	crateMaterial.uvVariants = [
		[0, 0, 0, 0],
		[0.03, 0, 1, 0],
		[0.06, 0, 2, 1],
		[0.09, 0, 3, 0],
	];
	for (const [i, [x, z, r]] of [[-2.4, 0.9, 0.2], [-1.5, 1.7, -0.5], [2.2, 1.1, 0.8], [3.1, 2.0, 0.1]].entries()) {
		const crate = new three.Mesh(crateGeometry);
		crate.material = crateMaterial;
		crate.variant = i;
		crate.position.set(x, 0.5, z);
		crate.rotation.y = r;
		scene.add(crate);
	}

	// The decals: one plane, one material, five copies, five different cracks —
	// and the wall behind them is still the same brick strip it was.
	//
	// A few millimetres proud of the wall's front face, which is what a decal on
	// a flat receiver costs: a coplanar quad z-fights, and there is no depth bias
	// on a pipeline here to lift one without moving it. At a grazing angle a
	// large offset would visibly float, so it is kept to two millimetres over a
	// two-metre band.
	//
	// `scale` and not a second geometry: two sizes of one shape are one asset and
	// one draw call, and a new `PlaneGeometry(w, h)` for each would be five.
	const crackGeometry = new three.PlaneGeometry(1, 1);
	const crackMaterial = new three.ShaderMaterial({ fragment: CRACK });
	const WALL_FACE = -3 + 0.25 + 0.002;
	for (const [x, y, w, h, spin] of [
		[-4.7, 0.80, 2.4, 1.6, 0.05],
		[-1.4, 0.70, 2.0, 1.4, -0.6],
		[1.9, 0.95, 2.6, 1.5, 0.3],
		[4.6, 0.60, 2.2, 1.2, -0.2],
	]) {
		const decal = new three.Mesh(crackGeometry);
		decal.material = crackMaterial;
		decal.position.set(x, y, WALL_FACE);
		decal.scale.set(w, h, 1);
		decal.rotation.z = spin;
		scene.add(decal);
	}

	// A tiled plinth, and the sheet itself standing on it: an authoring tool has
	// to show the flat sheet beside the lit result or there is nothing to read a
	// mistake off. `plan.md` §25's last bullet, in two meshes.
	const plinth = new three.Mesh(new three.BoxGeometry(4.2, 0.5, 1.6));
	plinth.material = trimMaterial(maps, strip('tiles'), 4.2, 0.5);
	plinth.position.set(-7.2, 0.25, 4.0);
	plinth.rotation.y = 0.5;
	scene.add(plinth);

	const flat = new three.Mesh(new three.PlaneGeometry(3.8, 3.8));
	flat.material = new three.MeshLambertMaterial({ map: maps.color, side: three.DoubleSide });
	flat.position.set(-7.2, 2.4, 4.0);
	flat.rotation.y = 0.5;
	scene.add(flat);

	three.camera.lookAt(-2.4, 2.2, 0.6);
	three.camera.orbit(15, 11, 20);
}

// ---------------------------------------------------------------------------
// Reading the sheet back
//
// The maps are on the device and `texture.read` copies them off it, so the same
// run that wrote the PNGs can say what is actually in them. Three claims, and
// each one is a number rather than a look at the picture.
// ---------------------------------------------------------------------------

// The mean of a whole band rather than of one row: a single row lands on a mortar
// course or straight down a line of grout, and a strip's mortar is rougher than
// its brick on purpose, so a row is a reading of where it was taken.
function bandMean(pixels, k, channel) {
	const height = SIZE / STRIPS;
	const y0 = k * height;
	let sum = 0;
	let taps = 0;
	for (let y = y0 + 2; y < y0 + height - 2; y += 2) {
		for (let x = 0; x < SIZE; x += 2) {
			sum += pixels[(y * SIZE + x) * 4 + channel];
			taps++;
		}
	}
	return sum / taps / 255;
}

function report(maps, baked) {
	const orm = maps.orm.read();
	const normal = maps.normal.read();

	// 1. The layout and the orientation: strip k of the file is strip k of the
	//    table, which is what the scene below is about to assume. The band means
	//    sit above their strip's base number because the recess in each one —
	//    mortar, grout, the gap between two boards — is rougher on purpose.
	const roughness = LAYOUT.map((s, k) => ({
		strip: s.name,
		wanted: s.rough,
		read: +bandMean(orm, k, 1).toFixed(3),
		ao: +bandMean(orm, k, 0).toFixed(3),
	}));

	// 2. A tangent-space normal map is a unit vector per texel with z out of the
	//    surface. Mean x and y at 0.5 and no z below 0.5 is what that looks like
	//    from here, and a map that came back through an sRGB decode would not.
	let mx = 0;
	let my = 0;
	let minZ = 255;
	const step = 8;
	let taps = 0;
	for (let y = 0; y < SIZE; y += step) {
		for (let x = 0; x < SIZE; x += step) {
			const i = (y * SIZE + x) * 4;
			mx += normal[i];
			my += normal[i + 1];
			if (normal[i + 2] < minZ) minZ = normal[i + 2];
			taps++;
		}
	}

	// 3. The calibration bake against the closed form. h = 0.5 + A sin(2pi k u)
	//    has slope 2pi k A cos(2pi k u) per unit of u, which the bake scales by
	//    `relief` texels over `SIZE` texels of width — so every texel of
	//    trim_3.png is predictable before it is read, and a normal that is
	//    differentiated wrongly, scaled wrongly or encoded wrongly cannot agree
	//    with it by accident.
	const probe = maps.probeNormal.read();
	const y = Math.floor(SIZE / 2);
	let worst = 0;
	let at = 0;
	for (let x = 0; x < SIZE; x++) {
		const u = (x + 0.5) / SIZE;
		const slope = (2 * Math.PI * PROBE_WAVES * PROBE_AMPLITUDE * Math.cos(2 * Math.PI * PROBE_WAVES * u) * RELIEF) / SIZE;
		const nx = -slope / Math.sqrt(slope * slope + 1);
		const wanted = Math.round((nx * 0.5 + 0.5) * 255);
		const got = probe[(y * SIZE + x) * 4];
		if (Math.abs(got - wanted) > worst) {
			worst = Math.abs(got - wanted);
			at = x;
		}
	}

	// 4. The data round trip on its own, over 1024 known values: the probe's ORM
	//    is roughness = u across and metalness = v down. What this is really
	//    checking is `data()` — a byte written through an sRGB attachment and
	//    read back through a linear view is the number the body meant, or the
	//    whole sheet is quietly wrong by a gamma.
	const ramp = maps.probeOrm.read();
	let rampWorst = 0;
	for (let x = 0; x < SIZE; x++) {
		const wanted = Math.round(((x + 0.5) / SIZE) * 255);
		rampWorst = Math.max(rampWorst, Math.abs(ramp[(y * SIZE + x) * 4 + 1] - wanted));
	}
	const mid = Math.floor(SIZE / 2);
	for (let v = 0; v < SIZE; v++) {
		const wanted = Math.round(((v + 0.5) / SIZE) * 255);
		rampWorst = Math.max(rampWorst, Math.abs(ramp[(v * SIZE + mid) * 4 + 2] - wanted));
	}

	const stats = three.stats();

	// `console.log` rather than `three.debug.write`: this whole file runs as the
	// boot script, so there is no next run to report a debug entry to.
	//
	// The checks below run either way, and that is the point of running them on
	// the files rather than on the frames: a reused sheet is verified on the way
	// in, so a stale or truncated one says so here instead of turning up as a
	// scene that looks slightly wrong.
	console.log(`sheet ${SIZE}x${SIZE}, ${STRIPS} strips of ${SIZE / STRIPS}, relief ${RELIEF} texels`);
	console.log(baked
		? '  baked this run'
		: '  read back from build/ — rm build/trim_*.png to bake it again');
	for (const s of MAPS) console.log(`  ${s.file}  ${s.what}`);
	console.log(`  ${SCENE_SHOT}  scene`);
	console.log('read back out of the ORM: green is roughness, red is occlusion');
	for (const r of roughness) {
		console.log(`  ${r.strip.padEnd(9)} base ${r.wanted.toFixed(2)}   band mean ${r.read.toFixed(3)}   ao ${r.ao.toFixed(3)}`);
	}
	console.log(`orm round trip: worst error ${rampWorst}/255 over a 0..1 ramp each way`);
	console.log(
		`normal map: mean x ${(mx / taps / 255).toFixed(4)}, mean y ${(my / taps / 255).toFixed(4)}, `
		+ `min z ${(minZ / 255).toFixed(4)} over ${taps} taps`
	);
	console.log(
		`probe: baked normal vs the closed form of h = 0.5 + ${PROBE_AMPLITUDE} sin(2pi ${PROBE_WAVES} u) — `
		+ `worst error ${worst}/255 at texel ${at} of ${SIZE}`
	);
	console.log(
		`scene: ${stats.drawCalls} draw calls, ${stats.instances} instances, ${stats.materials} materials, `
		+ `${stats.textures} textures, ${(stats.textureBytes / (1024 * 1024)).toFixed(2)} MiB`
	);
}
