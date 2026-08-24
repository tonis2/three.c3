// vfx.js — what a material's own samplers are for
//
// Run it:
//
//     ./build/three --script examples/vfx.js
//     ./build/three --script examples/vfx.js --mcp   # and attach an agent to it
//
// or paste it into `run_script` against a `./build/three --mcp` — the two are
// the same thing, which is why `--script` runs a file as a script and not as a
// module.
//
// Keys: space fires the cannon (shield hit + shockwave), `d` dissolves the
// crates, `g` toggles the grade, `o` stops and starts the orbit, `1` shows the
// shield's channels one at a time. Left alone it fires itself every ~4s.
//
// What it is here to show
// -----------------------
// **A ShaderMaterial can declare its own samplers, and never writes a binding
// number.** `textures: { noise_map, warp_map, ramp_map }` becomes three
// `[vk::binding(n, 0)] Sampler2D` lines in the generated module; the host reads
// the indices back out of the compiled shader's own reflection and resolves them
// by name. Reordering the object renumbers everything and changes nothing.
//
// **That is the difference between one image and an effect.** Every material
// below is the same three-part recipe a real VFX shader is: a *pattern* to
// animate, a *ramp* to colour it through, and a *mask* that says where. With one
// texture slot each of these is a pre-baked flipbook; with three they are
// arithmetic, and the arithmetic is what makes them respond to a hit.
//
// **Sample with whatever uv you like** — that is the whole point of the sampler
// being yours rather than the renderer's. `s.uv + float2(t, 0)` scrolls,
// `s.uv * 3` tiles, `float2(k, 0.5)` reads a gradient as a lookup table, and two
// noise taps at different speeds multiplied together is fire.
//
// **discard is how a dissolve works here.** `shade()` returns rgb and never
// alpha, deliberately — so a body cannot make geometry vanish by accident. A
// body that *means* to, discards, and the burn edge is a ramp lookup on the
// distance from the threshold.
//
// **Geometry moves in the vertex stage, and nothing is re-uploaded.** Four of the
// materials below carry a `void displace(inout Vertex v)` body: the dome bulges
// where it is hit, the plasma core boils along its own normals, the banners wave
// from their own local length, and the crates come apart per vertex as the
// dissolve front passes. The meshes are the same assets they were, the copies are
// still instanced, and the whole thing is a handful of floats a frame.
//
// **Every one of them says `bounds`.** Culling tests a mesh's own box, so a body
// that pushes vertices outside it draws something the frustum was never told
// about — the geometry vanishes near the edge of the screen and comes back when
// the camera turns. The number is how far the body can move a vertex.
//
// **The shield's rim needs the camera, and the camera is a uniform.** There is
// no view vector in `Surface`, so the loop computes the eye from the turntable
// and writes it as a 3-float uniform every frame — 12 bytes, no compile.
//
// **The post pass has samplers too.** A colour ramp to grade through and a grain
// field to dither with are exactly the two things a frame cannot supply about
// itself. The shockwave is a uv displacement sampling `scene` at an offset, so
// it is one pass and not two.
//
// The whole scene is 6 draw calls. The 24 crates are one of them, the 15 pieces
// of the plasma core are another, and the four banners are a third.

// ---------------------------------------------------------------------------
// Pixels
//
// All four are built once, here, and never again: a DataTexture is on the device
// when the constructor returns, and generating one costs real JavaScript time.
// ---------------------------------------------------------------------------

// Value noise, tiling. `cells` is how many across, so the same function gives
// both the coarse warp field and the fine detail without two generators.
function noiseTexture(size, cells, seed) {
	const grid = [];
	let s = seed >>> 0;
	const rand = () => ((s = (s * 1664525 + 1013904223) >>> 0) / 4294967296);
	for (let i = 0; i < cells * cells; i++) grid.push(rand());
	const at = (x, y) => grid[((y % cells) + cells) % cells * cells + ((x % cells) + cells) % cells];
	const fade = (t) => t * t * (3 - 2 * t);

	const px = new Uint8Array(size * size * 4);
	for (let y = 0; y < size; y++) {
		for (let x = 0; x < size; x++) {
			const fx = x / size * cells, fy = y / size * cells;
			const ix = Math.floor(fx), iy = Math.floor(fy);
			const tx = fade(fx - ix), ty = fade(fy - iy);
			const a = at(ix, iy), b = at(ix + 1, iy), c = at(ix, iy + 1), d = at(ix + 1, iy + 1);
			const n = (a + (b - a) * tx) + ((c + (d - c) * tx) - (a + (b - a) * tx)) * ty;
			const v = Math.round(n * 255);
			const i = (y * size + x) * 4;
			px[i] = v; px[i + 1] = v; px[i + 2] = v; px[i + 3] = 255;
		}
	}
	return new three.DataTexture(px, size, size);
}

// A gradient, read as a lookup table: sample it at float2(k, 0.5) and k picks
// the colour. `stops` are [position, r, g, b] with the channels in 0..255.
function rampTexture(width, stops) {
	const px = new Uint8Array(width * 4 * 4);
	for (let x = 0; x < width; x++) {
		const t = x / (width - 1);
		let lo = stops[0], hi = stops[stops.length - 1];
		for (let i = 0; i < stops.length - 1; i++) {
			if (t >= stops[i][0] && t <= stops[i + 1][0]) { lo = stops[i]; hi = stops[i + 1]; break; }
		}
		const span = Math.max(hi[0] - lo[0], 1e-5);
		const k = Math.min(Math.max((t - lo[0]) / span, 0), 1);
		for (let row = 0; row < 4; row++) {
			const i = (row * width + x) * 4;
			px[i] = lo[1] + (hi[1] - lo[1]) * k;
			px[i + 1] = lo[2] + (hi[2] - lo[2]) * k;
			px[i + 2] = lo[3] + (hi[3] - lo[3]) * k;
			px[i + 3] = 255;
		}
	}
	return new three.DataTexture(px, width, 4);
}

// A hex lattice, as lines. This is the shield's *pattern* — the thing that
// scrolls, catches the rim and shows where the impact ring has reached.
function hexTexture(size) {
	const px = new Uint8Array(size * size * 4);
	for (let y = 0; y < size; y++) {
		for (let x = 0; x < size; x++) {
			// Three line families at 60 degrees to each other make hexagons.
			const u = x / size, v = y / size;
			let edge = 0;
			for (const a of [0, Math.PI / 3, -Math.PI / 3]) {
				const d = Math.abs(((u * Math.cos(a) + v * Math.sin(a)) * 6) % 1 - 0.5);
				edge = Math.max(edge, 1 - Math.min(d * 9, 1));
			}
			const c = Math.round(edge * 255);
			const i = (y * size + x) * 4;
			px[i] = c; px[i + 1] = c; px[i + 2] = c; px[i + 3] = 255;
		}
	}
	return new three.DataTexture(px, size, size);
}

// Plain metal plate for the crates, so the dissolve has something recognisable
// to eat through.
function plateTexture(size) {
	const px = new Uint8Array(size * size * 4);
	for (let y = 0; y < size; y++) {
		for (let x = 0; x < size; x++) {
			const border = x < 3 || y < 3 || x >= size - 3 || y >= size - 3;
			const rivet = ((x - 8) ** 2 + (y - 8) ** 2 < 9) || ((x - size + 8) ** 2 + (y - size + 8) ** 2 < 9);
			const c = border ? [126, 136, 152] : rivet ? [178, 186, 198] : [82, 90, 104];
			const i = (y * size + x) * 4;
			px[i] = c[0]; px[i + 1] = c[1]; px[i + 2] = c[2]; px[i + 3] = 255;
		}
	}
	return new three.DataTexture(px, size, size);
}

const coarse = noiseTexture(128, 8, 12345);
const fine = noiseTexture(128, 24, 777);
const hex = hexTexture(128);
const plate = plateTexture(64);

// Fire: black through red and orange to a white core.
const fireRamp = rampTexture(64, [
	[0.00, 4, 2, 6], [0.30, 120, 20, 10], [0.55, 235, 90, 20],
	[0.80, 255, 190, 70], [1.00, 255, 250, 225],
]);
// Shield: deep blue through cyan to white.
const shieldRamp = rampTexture(64, [
	[0.00, 6, 14, 40], [0.45, 30, 110, 210], [0.80, 120, 220, 255], [1.00, 255, 255, 255],
]);
// The burn edge a dissolve leaves behind.
const burnRamp = rampTexture(64, [
	[0.00, 255, 240, 200], [0.35, 255, 140, 30], [0.75, 90, 20, 8], [1.00, 8, 6, 6],
]);
// The banners: warm, so they read against the shield rather than into it.
const clothRamp = rampTexture(64, [
	[0.00, 58, 26, 18], [0.40, 168, 74, 34], [0.75, 232, 148, 62], [1.00, 255, 216, 150],
]);
// The post grade: a slightly cool, lifted-black filmic curve.
const gradeLut = rampTexture(64, [
	[0.00, 14, 16, 26], [0.25, 62, 70, 92], [0.55, 140, 140, 150],
	[0.80, 215, 208, 195], [1.00, 255, 250, 240],
]);

// ---------------------------------------------------------------------------
// The arena
// ---------------------------------------------------------------------------

const scene = new three.Scene();
scene.background = [0.02, 0.025, 0.04];
// Positive Y in the direction is what lights the tops of things — the vector
// points from the surface *to* the light.
three.light.set([-0.3, 0.85, 0.4], 0.24);

const floorMat = new three.MeshLambertMaterial({ map: plate });
floorMat.repeat = [12, 12];
const ground = new three.Mesh(new three.PlaneGeometry(60, 60), floorMat);
ground.rotation.x = -Math.PI / 2;
scene.add(ground);

// ---------------------------------------------------------------------------
// 1. The shield — three samplers, and a camera in a uniform
//
// hex_map    the lattice, scrolling, and what the impact ring lights up
// noise_map  breakup, so the rim is not a clean mathematical edge
// ramp_map   every colour in the effect, indexed by intensity
//
// `eye` is written by the animation loop. There is no view vector in Surface —
// the turntable's position is a script-side fact, so it crosses as 12 bytes of
// uniform and the fresnel is computed from it here.
// ---------------------------------------------------------------------------

const shieldMat = new three.ShaderMaterial({
	blending: three.AdditiveBlending,
	side: three.DoubleSide,
	fragment: `
	// A ramp is 64 texels wide and the sampler repeats, so sampling at 0 or 1
	// lands on the seam and blends the two ENDS of the gradient together — the
	// darkest input comes back as the brightest colour, over the whole frame,
	// which looks like a shader bug and is a wrap mode. Half a texel in at each
	// end is the fix, and it is why every lookup here goes through this.
	float2 lut(float k)
	{
	    return float2(0.0078 + saturate(k) * 0.9844, 0.5);
	}

	float3 shade(Surface s)
	{
	    float3 n = normalize(s.normal);
	    float3 v = normalize(eye - s.position);

	    // The rim: everything that faces away from the camera glows.
	    //
	    // **abs, not saturate.** This material is DoubleSide, so the far half of
	    // the dome has normals pointing away from the eye and a clamped dot
	    // product there is zero — which is a rim of 1 over the entire back
	    // surface, added on top of the front one. The magnitude is the angle
	    // either way round, and the shield wants the angle.
	    float facing = abs(dot(n, v));
	    float rim = pow(1.0 - facing, 3.0);

	    // The lattice, drifting, broken up by the coarse field so it reads as
	    // energy rather than as a decal.
	    float drift = noise_map.Sample(s.uv * 2.0 + float2(t * 0.03, t * 0.02)).r;
	    float cells = hex_map.Sample(s.uv * 3.0 + float2(t * 0.02, 0.0) + drift * 0.05).r;

	    // The impact ring: a band travelling down from the top of the dome,
	    // expanding as it goes. hit is 1 at the moment of impact and decays.
	    float band = 1.0 - abs(s.uv.y - (1.0 - hit)) * 8.0;
	    float ring = saturate(band) * hit;

	    float energy = saturate(rim * 0.9 + cells * (0.12 + rim * 0.5) + ring * 1.6);
	    float3 colour = ramp_map.Sample(lut(energy)).rgb;

	    // Channel view, for the 1 key: 1 rim, 2 lattice, 3 ring, 0 the lot.
	    if (channel > 0.5 && channel < 1.5) return float3(rim);
	    if (channel > 1.5 && channel < 2.5) return float3(cells);
	    if (channel > 2.5) return float3(ring);

	    return colour * energy * 1.5;
	}`,
	// The dome does not merely light up where it is hit — it moves. The same
	// travelling band the fragment body draws is pushed out along the surface
	// normal here, so the impact has a shape from every angle instead of being a
	// picture painted on a sphere.
	//
	// `v.local` rather than `v.position`: the band should ride the dome's own
	// parameterisation wherever the dome is, not a plane of the world.
	vertex: `
	void displace(inout Vertex v)
	{
	    float band = 1.0 - abs(v.uv.y - (1.0 - hit)) * 8.0;
	    // Not called push: a uniform reaches your body as push.name, so a local
	    // of that name shadows the block every one of them goes through, and the
	    // error arrives as "t is not a member of float" against a line of
	    // generated code you have never seen.
	    float bulge = saturate(band) * hit;
	    // A little breathing even at rest, so the shield reads as held rather
	    // than as a static mesh waiting for something to happen.
	    float idle = sin(t * 1.6 + v.local.y * 0.8) * 0.03;
	    v.position += normalize(v.normal) * (bulge * 0.55 + idle);
	}`,
	bounds: 0.6,
	uniforms: { eye: [0, 0, 0], t: 0, hit: 0, channel: 0 },
	textures: { hex_map: hex, noise_map: coarse, ramp_map: shieldRamp },
});

const shield = new three.Mesh(new three.SphereGeometry(7.5, 48, 32), shieldMat);
shield.position.set(0, 0.2, 0);
scene.add(shield);

// ---------------------------------------------------------------------------
// 2. The plasma core — the canonical fire recipe
//
// warp_map moves the coordinate the pattern is read at, which is what turns two
// scrolling noise fields into something that curls instead of sliding. Then the
// combined intensity indexes the ramp, so every colour in the fire comes out of
// one 64-pixel image and none of it is in the shader.
// ---------------------------------------------------------------------------

const coreMat = new three.ShaderMaterial({
	blending: three.AdditiveBlending,
	fragment: `
	// A ramp is 64 texels wide and the sampler repeats, so sampling at 0 or 1
	// lands on the seam and blends the two ENDS of the gradient together — the
	// darkest input comes back as the brightest colour, over the whole frame,
	// which looks like a shader bug and is a wrap mode. Half a texel in at each
	// end is the fix, and it is why every lookup here goes through this.
	float2 lut(float k)
	{
	    return float2(0.0078 + saturate(k) * 0.9844, 0.5);
	}

	float3 shade(Surface s)
	{
	    float2 warp = warp_map.Sample(s.uv * 1.5 - float2(0.0, t * 0.10)).rg - 0.5;
	    float2 uv = s.uv + warp * 0.22;

	    float a = noise_map.Sample(uv * 2.0 - float2(0.0, t * 0.35)).r;
	    float b = noise_map.Sample(uv * 4.0 + float2(t * 0.11, -t * 0.6)).r;

	    // Hotter towards the middle of the sphere's parameterisation, so the
	    // shape reads as a core with a corona rather than as a noisy ball.
	    float falloff = 1.0 - abs(s.uv.y - 0.5) * 1.7;
	    float heat = saturate(a * b * 3.2 * saturate(falloff)) * gain;

	    return ramp_map.Sample(lut(heat)).rgb * heat * 2.2;
	}`,
	// The core boils. Two noise taps at different speeds along the normal, which
	// is what makes a sphere read as a mass of burning gas rather than as a
	// sphere with fire painted on it.
	//
	// **SampleLevel, not Sample.** A vertex shader has no neighbouring fragments
	// to derive a mip level from, so the LOD is stated. This is the one thing
	// about sampling that differs between the two stages.
	vertex: `
	void displace(inout Vertex v)
	{
	    float a = warp_map.SampleLevel(v.uv * 2.0 + float2(0.0, t * 0.20), 0).r;
	    float b = noise_map.SampleLevel(v.uv * 3.0 - float2(t * 0.15, 0.0), 0).r;
	    v.position += normalize(v.normal) * ((a + b - 1.0) * 0.42 * gain);
	}`,
	bounds: 0.6,
	uniforms: { t: 0, gain: 1 },
	textures: { noise_map: fine, warp_map: coarse, ramp_map: fireRamp },
});

const core = new three.Mesh(new three.SphereGeometry(1.5, 32, 24), coreMat);
core.position.set(0, 3.2, 0);
scene.add(core);

// A few embers orbiting it, sharing the material — additive, so their order
// against each other does not matter and they stay one draw call.
const embers = [];
const emberGeo = new three.SphereGeometry(0.28, 12, 8);
for (let i = 0; i < 14; i++) {
	const e = new three.Mesh(emberGeo, coreMat);
	e.color = [1, 0.85 + 0.15 * (i % 3), 0.7, 1];
	// Placed here as well as in the loop: a screenshot taken before the first
	// tick would catch all fourteen of them stacked at the origin, under the
	// floor, which reads as the embers not working rather than as not having
	// moved yet.
	const a = i * 0.45, r = 2.1 + (i % 3) * 0.7;
	e.position.set(Math.cos(a) * r, 3.2 + Math.sin(i) * 0.8, Math.sin(a) * r);
	scene.add(e);
	embers.push(e);
}

// ---------------------------------------------------------------------------
// 3. The dissolving crates — discard, and a ramp for the burn edge
//
// `shade()` never returns alpha, so this is the only way for a body to make
// geometry go: sample the noise, discard below the threshold, and colour the
// band just above it out of the ramp. 24 crates, one material, one draw call —
// the dissolve is per pixel and the cost is not per crate.
// ---------------------------------------------------------------------------

const dissolveMat = new three.ShaderMaterial({
	fragment: `
	// A ramp is 64 texels wide and the sampler repeats, so sampling at 0 or 1
	// lands on the seam and blends the two ENDS of the gradient together — the
	// darkest input comes back as the brightest colour, over the whole frame,
	// which looks like a shader bug and is a wrap mode. Half a texel in at each
	// end is the fix, and it is why every lookup here goes through this.
	float2 lut(float k)
	{
	    return float2(0.0078 + saturate(k) * 0.9844, 0.5);
	}

	float3 shade(Surface s)
	{
	    float n = noise_map.Sample(s.uv * 1.1).r;

	    // Everything the front has already passed is gone. Not faded — gone:
	    // there is no alpha to fade, and a discard leaves the depth buffer
	    // correct for whatever is behind it.
	    if (n < edge) discard;

	    float3 plate = plate_map.Sample(s.uv).rgb * lambert(s.normal);

	    // The band just ahead of the front, read through the burn ramp so the
	    // edge glows white-hot and cools off over about a tenth of the range.
	    //
	    // Gated on the front having actually started: at edge 0 the band would
	    // still cover every pixel whose noise is under about a tenth, which is a
	    // crate speckled with embers before anything has been asked to dissolve.
	    float heat = edge < 0.002 ? 0.0 : saturate(1.0 - (n - edge) * 9.0);
	    float3 burn = ramp_map.Sample(lut(1.0 - heat)).rgb;

	    return lerp(plate, burn * 2.4, heat * heat);
	}`,
	// The crates come apart rather than simply thinning out. `v.index` is the
	// vertex number — a per-vertex seed, and the only thing in `Vertex` that
	// gives two corners of one face a reason to differ. Hashed into a direction,
	// it scatters the surviving geometry as the front eats through it.
	vertex: `
	float hash11(float x)
	{
	    return frac(sin(x * 12.9898) * 43758.5453);
	}
	void displace(inout Vertex v)
	{
	    if (edge < 0.002) return;
	    float3 dir = normalize(float3(
	        hash11(float(v.index) * 1.0) - 0.5,
	        hash11(float(v.index) * 2.3) * 0.6,
	        hash11(float(v.index) * 3.7) - 0.5
	    ) + 1e-5);
	    v.position += dir * edge * edge * 0.9;
	}`,
	bounds: 1.0,
	uniforms: { edge: 0 },
	textures: { plate_map: plate, noise_map: coarse, ramp_map: burnRamp },
});

const crateGeo = new three.BoxGeometry(1.1, 1.1, 1.1);
const crates = [];
for (let i = 0; i < 24; i++) {
	const a = (i / 24) * Math.PI * 2;
	const r = 4.6 + (i % 3) * 0.5;
	const c = new three.Mesh(crateGeo, dissolveMat);
	c.position.set(Math.cos(a) * r, 0.55 + (i % 2) * 1.1, Math.sin(a) * r);
	c.rotation.y = a;
	scene.add(c);
	crates.push(c);
}


// ---------------------------------------------------------------------------
// 4. The banners — the canonical vertex effect, and the one that needs a normal
//
// A flag is where a vertex body earns its place: the geometry is a flat grid, the
// wave is two sines, and the mesh never changes. What makes it look like cloth
// rather than like a wobbling plane is the *normal* — nothing recomputes it for
// you, so the body writes the one the wave implies and the lighting rolls with
// the fabric.
//
// `v.local` is the input, not `v.position`: the wave should run along the
// banner's own length wherever the banner is standing, and world space would make
// four flags around a circle wave in four different directions.
// ---------------------------------------------------------------------------

const bannerMat = new three.ShaderMaterial({
	side: three.DoubleSide,
	vertex: `
	void displace(inout Vertex v)
	{
	    // Pinned at the top edge, free at the bottom: the amplitude grows with
	    // distance from the pole, which is what stops it looking like a sheet
	    // being waved from both ends.
	    float droop = saturate(0.5 - v.local.y);
	    float wave = sin(v.local.y * 2.6 - t * 2.4) + 0.4 * sin(v.local.x * 3.1 + t * 1.7);
	    v.position.z += wave * droop * 0.55;

	    // The normal the wave implies: the surface tilts by the slope of the
	    // displacement, so the derivative of the sine is the whole of it. Without
	    // this the banner moves and the shading does not, which reads as a
	    // texture sliding over a still object.
	    float slope = cos(v.local.y * 2.6 - t * 2.4) * 2.6 * droop * 0.55;
	    v.normal = normalize(float3(v.normal.x, v.normal.y - slope, 1.0));
	}`,
	bounds: 0.7,
	fragment: `
	float2 lut(float k)
	{
	    return float2(0.0078 + saturate(k) * 0.9844, 0.5);
	}
	float3 shade(Surface s)
	{
	    float3 cloth = ramp_map.Sample(lut(1.0 - s.uv.y * 0.8)).rgb;
	    return cloth * s.color.rgb * (0.35 + 0.65 * lambert(s.normal));
	}`,
	uniforms: { t: 0 },
	textures: { ramp_map: clothRamp },
});

const bannerGeo = new three.PlaneGeometry(1.7, 3.4, 8, 14);
const banners = [];
for (let i = 0; i < 4; i++) {
	const a = (i / 4) * Math.PI * 2 + Math.PI / 4;
	const b = new three.Mesh(bannerGeo, bannerMat);
	b.position.set(Math.cos(a) * 11.5, 2.4, Math.sin(a) * 11.5);
	b.rotation.y = -a + Math.PI / 2;
	b.color = i % 2 ? [1, 0.9, 0.75, 1] : [1, 0.75, 0.55, 1];
	scene.add(b);
	banners.push(b);
}

// ---------------------------------------------------------------------------
// 5. The post pass — a grade to look through and a grain to dither with
//
// The shockwave is a uv displacement: sample `scene` at an offset that rides an
// expanding ring, rather than a second pass over a blurred copy. One pass is all
// there is, so an effect that wants two has to become arithmetic.
// ---------------------------------------------------------------------------

const POST_BODY = `
// The same half-texel inset the materials use: a lookup table sampled at 0 or 1
// under a repeating sampler blends the two ends of the ramp together, and the
// symptom is a frame that comes back the colour of the ramp's bright end.
float2 lut(float k)
{
    return float2(0.0078 + saturate(k) * 0.9844, 0.5);
}

float3 post(Post p)
{
    float2 uv = p.uv;

    // The ring, in aspect-corrected space so it is a circle and not an ellipse.
    float aspect = p.resolution.x / p.resolution.y;
    float2 d = float2((uv.x - centre.x) * aspect, uv.y - centre.y);
    float r = length(d);

    // The ring is computed whether or not it is showing, because the flash at
    // the bottom rides it too — and a flash added to the whole frame instead is
    // the one thing that cannot be got away with here. Near-black is 0.005 in
    // linear, so a flat 0.05 lifts the background to mid-grey and the effect
    // reads as the exposure breaking rather than as an impact.
    float front = (1.0 - shock) * 0.9;
    float ring = (1.0 - saturate(abs(r - front) * 14.0)) * shock;
    uv += normalize(d + 1e-5) * ring * 0.05;

    float3 c = scene.Sample(uv).rgb;

    // Grade: each channel through the ramp at its own level. A lookup table is
    // one texture and a curve nobody has to write.
    float3 graded = float3(
        grade_lut.Sample(lut(c.r)).r,
        grade_lut.Sample(lut(c.g)).g,
        grade_lut.Sample(lut(c.b)).b
    );
    c = lerp(c, graded, amount);

    // Grain, tiled by the frame rather than by uv so it does not stretch with
    // the window, and scrolled so it is not a fixed pattern.
    float g = grain_map.Sample(p.uv * p.resolution / 128.0 + float2(frac(p.time * 7.0), frac(p.time * 3.0))).r;
    c += (g - 0.5) * grain;

    // The flash, on the ring and nowhere else.
    c += float3(0.55, 0.75, 1.0) * ring * ring * 0.5;
    c *= 1.0 - smoothstep(0.35, 0.95, r) * 0.55;

    return c;
}`;

// ---------------------------------------------------------------------------
// State, keys, loop
//
// Each run_script call has its own scope, so anything a later call or a handler
// needs has to live here.
// ---------------------------------------------------------------------------

const V = globalThis.vfx = {
	scene, shield, core, embers, crates, banners,
	shieldMat, coreMat, dissolveMat, bannerMat,
	pass: null, post: POST_BODY,
	now: 0, hit: 0, mark: 0, auto: true,
	dissolving: false, edge: 0, grade: true, orbit: true, channel: 0,
};

// The turntable's eye, which the fresnel needs and Surface does not carry.
// `three.camera` is an orbit: target plus a direction built from yaw and pitch.
V.eye = () => {
	const c = three.camera;
	const yaw = c.yaw * Math.PI / 180, pitch = c.pitch * Math.PI / 180;
	const h = Math.cos(pitch);
	return [
		c.target.x + h * Math.sin(yaw) * c.distance,
		c.target.y + Math.sin(pitch) * c.distance,
		c.target.z + h * Math.cos(yaw) * c.distance,
	];
};

V.fire = () => {
	V.hit = 1;
	V.mark = V.now;
	if (V.pass) V.pass.uniforms.shock = 1;
};

V.setGrade = (on) => {
	V.grade = on;
	if (V.pass) V.pass.uniforms.amount = on ? 0.85 : 0;
};

three.onKeyDown('space', () => V.fire());
three.onKeyDown('d', () => { V.dissolving = !V.dissolving; });
three.onKeyDown('g', () => V.setGrade(!V.grade));
three.onKeyDown('o', () => { V.orbit = !V.orbit; });
three.onKeyDown('1', () => {
	V.channel = (V.channel + 1) % 4;
	V.shieldMat.uniforms.channel = V.channel;
});

three.setAnimationLoop(() => {
	// Both readings off the game clock: `t` is what the shader uniforms want and
	// `dt` is what the decays below want. Every decay here used to be a constant
	// per *frame*, which is a fade that is twice as fast on a machine drawing
	// twice as often — the bug a clock exists to make unwritable.
	const t = three.clock.time;
	const dt = three.clock.dt;
	V.now = t;

	// Every one of these is a push-block write: no compile, no pipeline, and
	// nothing re-uploaded. The textures behind them never move.
	V.shieldMat.uniforms.t = t;
	V.shieldMat.uniforms.eye = V.eye();
	V.coreMat.uniforms.t = t;
	V.bannerMat.uniforms.t = t;
	V.coreMat.uniforms.gain = 0.85 + 0.15 * Math.sin(t * 3.1);

	// The impact decays over about half a second.
	V.hit = Math.max(0, V.hit - dt * 2.1);
	V.shieldMat.uniforms.hit = V.hit;

	if (V.pass) {
		const shock = Math.max(0, (V.pass.uniforms.shock ?? 0) - dt * 1.32);
		V.pass.uniforms.shock = shock;
	}

	// The dissolve front sweeps up and back down, so the crates come back.
	V.edge = V.dissolving
		? Math.min(1.02, V.edge + dt * 0.72)
		: Math.max(0, V.edge - dt * 1.2);
	V.dissolveMat.uniforms.edge = V.edge;

	// Embers, on two rings turning at different rates.
	for (const [i, e] of V.embers.entries()) {
		const a = t * (0.7 + (i % 4) * 0.16) + i * 0.45;
		const r = 2.1 + (i % 3) * 0.7;
		e.position.set(Math.cos(a) * r, 3.2 + Math.sin(t * 1.4 + i) * 0.8, Math.sin(a) * r);
	}

	if (V.orbit) three.camera.orbit(18 + 22 * Math.sin(t * 0.09));
	if (V.auto && t - V.mark > 4) V.fire();
});

V.pass = three.setPost({
	fragment: POST_BODY,
	uniforms: { amount: 0.85, shock: 0, centre: [0.5, 0.52], grain: 0.03 },
	textures: { grade_lut: gradeLut, grain_map: fine },
});

three.camera.lookAt(0, 2.6, 0);
three.camera.orbit(22, 12, 26);

// After the camera, and before anything renders: the loop writes `eye` every
// frame, but a screenshot taken before the first tick would catch it at the
// origin — which puts the fresnel inside the dome and lights the whole thing.
V.shieldMat.uniforms.eye = V.eye();

return {
	keys: {
		space: 'fire — shield ring and a shockwave through the post pass',
		d: 'dissolve the crates and bring them back',
		g: 'grade on/off',
		o: 'auto-orbit on/off',
		1: 'shield: all, rim, lattice, ring',
	},
	displaces: {
		shield: 'the dome bulges where it is hit',
		core: 'boils along its normals, sampling in the vertex stage',
		banners: 'wave from their own local length, normals rewritten',
		crates: 'come apart per vertex, seeded by v.index',
	},
	samplers: {
		shield: Object.keys(shieldMat.textures),
		banners: Object.keys(bannerMat.textures),
		core: Object.keys(coreMat.textures),
		crates: Object.keys(dissolveMat.textures),
		post: Object.keys(V.pass.textures),
	},
	stats: three.stats(),
};
