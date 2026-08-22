// blend_post.js — the blending modes and the post pass, in one window
//
// Paste into `run_script` against a serving instance:
//
//     ./build/three --mcp          # a window you can watch
//
// Keys once it is up:
//
//     1..5   post pass: grade, chroma+scanlines, bloom, ripple, toon
//     0      post off  (setPost(null))
//     space  cycle 1..5
//     [ ]    the post pass's `amount` down / up
//     o      auto-orbit on/off
//     g      the additive group on/off  (orbs, beams, dome)
//     t      the glass row on/off
//
// What it is here to show
// -----------------------
// **One row, three blend modes, identical crates behind them.** Seven crates
// stand in a line at even spacing, and in front of each is a panel. Left to
// right: one AdditiveBlending panel, five NormalBlending panels whose per-copy
// alpha steps 0.2 → 1.0, and one opaque panel. The crate behind each is the
// control — the additive panel never darkens its crate, the normal ones fade
// it out by degrees, the opaque one hides it.
//
// **The alpha ramp is one draw call.** The five normal-blended panels share one
// material and one geometry; what differs is `mesh.color`'s fourth channel,
// which is a per-copy channel like the tint is. Five levels of transparency,
// one bucket.
//
// **Blending is decided at construction.** `material.blending` is read-only
// here — this device bakes blending into the pipeline — so the three modes in
// the row are three materials, which is three lines. That is the whole cost.
//
// **Additive never darkens.** The three orbs are red, green and blue and they
// overlap: the pairs read yellow, magenta and cyan and the middle reads white.
// Nothing about the orbs is sorted or needs to be, which is the property that
// makes additive the mode for fire, beams and glows.
//
// **The post pass is one shader with a `mode` uniform.** Keys 1..5 write four
// bytes; there is no recompile and no pipeline built, which is what makes an
// animated post pass free. `0` clears the pass outright and pressing 1..5
// again compiles it back — from the disk shader cache the second time, so it
// comes back without the pause the first one had.
//
// **What the window shows is what a screenshot returns.** The post pass lives
// in the one recording path both go through, so `screenshot` comes back with
// the grade, the scanlines and the bloom on it.

function checkerTexture(size, cells, a, b) {
	const px = new Uint8Array(size * size * 4);
	const cell = size / cells;
	for (let y = 0; y < size; y++) {
		for (let x = 0; x < size; x++) {
			const on = ((Math.floor(x / cell) + Math.floor(y / cell)) & 1) === 1;
			const c = on ? a : b;
			const i = (y * size + x) * 4;
			px[i] = c[0]; px[i + 1] = c[1]; px[i + 2] = c[2]; px[i + 3] = 255;
		}
	}
	return new three.DataTexture(px, size, size);
}

function brickTexture(size) {
	const px = new Uint8Array(size * size * 4);
	const rowH = size / 4, brickW = size / 2, mortar = 3;
	for (let y = 0; y < size; y++) {
		for (let x = 0; x < size; x++) {
			const shift = (Math.floor(y / rowH) & 1) ? brickW / 2 : 0;
			const seam = (y % rowH) < mortar || ((x + shift) % brickW) < mortar;
			const c = seam ? [186, 182, 174] : [138, 70, 56];
			const i = (y * size + x) * 4;
			px[i] = c[0]; px[i + 1] = c[1]; px[i + 2] = c[2]; px[i + 3] = 255;
		}
	}
	return new three.DataTexture(px, size, size);
}

const scene = new three.Scene();
three.light.set([-0.35, 0.9, 0.45], 0.34);

// ---------------------------------------------------------------- the room

const floorTex = checkerTexture(64, 2, [104, 106, 116], [196, 196, 200]);
const brickTex = brickTexture(64);

const floorMat = new three.MeshLambertMaterial({ map: floorTex });
floorMat.repeat = [24, 24];
const ground = new three.Mesh(new three.PlaneGeometry(64, 48), floorMat);
ground.name = 'ground';
ground.rotation.x = -Math.PI / 2;
scene.add(ground);

const wallMat = new three.MeshLambertMaterial({ map: brickTex });
wallMat.repeat = [16, 4];
const backWall = new three.Mesh(new three.PlaneGeometry(64, 16), wallMat);
backWall.name = 'wall';
backWall.position.set(0, 8, -18);
scene.add(backWall);

// ------------------------------------------------- the controls behind glass

// Seven identical crates, evenly spaced, each one the control for the panel in
// front of it. Different tints, one draw call — colour is a per-copy channel.
const crateGeo = new three.BoxGeometry(2.6, 2.6, 2.6);
const crateMat = new three.MeshLambertMaterial({ map: floorTex });
const SLOTS = [-12, -8, -4, 0, 4, 8, 12];
const crates = SLOTS.map((x, k) => {
	const box = new three.Mesh(crateGeo, crateMat);
	box.name = `crate_${k}`;
	box.position.set(x, 1.3, -8);
	box.rotation.y = 0.35 + k * 0.14;
	box.color = [0.95, 0.55 + 0.05 * k, 0.28, 1];
	scene.add(box);
	return box;
});

// ------------------------------------------------------------ the blend row

const paneGeo = new three.PlaneGeometry(3.4, 4.4);

// Three materials because blending is baked into the pipeline. Each is one line.
const glassMat = new three.MeshLambertMaterial({ transparent: true, side: three.DoubleSide });
const solidMat = new three.MeshLambertMaterial({ side: three.DoubleSide });
const addPaneMat = new three.MeshLambertMaterial({ blending: three.AdditiveBlending, side: three.DoubleSide });

const panes = [];

// Far left: additive. It adds its own colour to the crate and can only
// brighten — the crate stays legible through it.
const addPane = new three.Mesh(paneGeo, addPaneMat);
addPane.name = 'pane_additive';
addPane.position.set(-12, 2.6, -3.4);
addPane.color = [0.10, 0.42, 0.62, 1];
scene.add(addPane);
panes.push(addPane);

// The middle five: one material, one geometry, five per-copy alphas. This is
// the ramp — 0.2 through 1.0 — and it is a single instanced draw call.
const ALPHAS = [0.2, 0.4, 0.6, 0.8, 1.0];
ALPHAS.forEach((a, k) => {
	const pane = new three.Mesh(paneGeo, glassMat);
	pane.name = `pane_alpha_${a}`;
	pane.position.set(SLOTS[k + 1], 2.6, -3.4);
	pane.color = [0.45, 0.85, 0.95, a];
	scene.add(pane);
	panes.push(pane);
});

// Far right: opaque, for the comparison to have an end. Same geometry, same
// tint, no blending — the crate behind it is gone.
const solidPane = new three.Mesh(paneGeo, solidMat);
solidPane.name = 'pane_opaque';
solidPane.position.set(12, 2.6, -3.4);
solidPane.color = [0.45, 0.85, 0.95, 1];
scene.add(solidPane);
panes.push(solidPane);

// ---------------------------------------------------- the additive group

// One ShaderMaterial for everything that glows. The body returns the copy's own
// colour times a pulse, so one material and one pipeline serve every glowing
// thing in the scene and each copy keeps its own colour.
const glowMat = new three.ShaderMaterial({
	blending: three.AdditiveBlending,
	side: three.DoubleSide,
	fragment: `
	float3 shade(Surface s)
	{
	    float pulse = 0.72 + 0.28 * sin(clock * 2.4 + s.position.x * 0.5 + s.position.z * 0.3);
	    return s.color.rgb * (gain * pulse);
	}`,
	uniforms: { clock: 0, gain: 1.25 },
});

// Red, green and blue, overlapping. The pairs are yellow, magenta and cyan and
// the middle is white — additive light, not paint.
const orbGeo = new three.SphereGeometry(1.6, 32, 16);
const ORB_Y = 9.4, ORB_Z = -6;
const ORBS = [
	{ at: [-1.35, ORB_Y, ORB_Z], color: [0.95, 0.12, 0.12] },
	{ at: [1.35, ORB_Y, ORB_Z], color: [0.12, 0.95, 0.16] },
	{ at: [0, ORB_Y - 1.5, ORB_Z], color: [0.16, 0.30, 0.98] },
];
const orbs = ORBS.map((o, k) => {
	const m = new three.Mesh(orbGeo, glowMat);
	m.name = `orb_${k}`;
	m.position.set(...o.at);
	m.color = [...o.color, 1];
	scene.add(m);
	return m;
});

// Beams. Thin, long, additive: where two cross, the crossing is brighter than
// either, and where one crosses a glass panel it lights the panel rather than
// being hidden by it.
const beamGeo = new three.BoxGeometry(48, 0.16, 0.16);
const BEAMS = [
	{ y: 6.6, z: -9, rz: 0.05, color: [0.20, 0.85, 1.0] },
	{ y: 5.6, z: -1, rz: -0.07, color: [1.0, 0.25, 0.75] },
	{ y: 11.4, z: 1, rz: 0.03, color: [1.0, 0.72, 0.20] },
];
const beams = BEAMS.map((b, k) => {
	const m = new three.Mesh(beamGeo, glowMat);
	m.name = `beam_${k}`;
	m.position.set(0, b.y, b.z);
	m.rotation.z = b.rz;
	m.color = [...b.color, 1];
	scene.add(m);
	return m;
});

// A dome over the whole thing: a grid and a sweep, additive and faint, drawn
// from the inside as well as the outside.
const domeMat = new three.ShaderMaterial({
	blending: three.AdditiveBlending,
	side: three.DoubleSide,
	fragment: `
	float3 shade(Surface s)
	{
	    float2 g = frac(s.uv * float2(64.0, 32.0));
	    float d = min(min(g.x, 1.0 - g.x), min(g.y, 1.0 - g.y));
	    float grid = smoothstep(0.09, 0.0, d);
	    float sweep = pow(0.5 + 0.5 * sin(s.uv.y * 12.0 - clock * 1.1), 8.0);
	    return tint * (grid * 0.22 + sweep * 0.5) * gain;
	}`,
	uniforms: { tint: [0.28, 0.62, 1.0], clock: 0, gain: 0.45 },
});
const dome = new three.Mesh(new three.SphereGeometry(22, 48, 24), domeMat);
dome.name = 'dome';
dome.position.set(0, 0, -4);
scene.add(dome);

// ------------------------------------------------------------- the post pass

// One shader, five looks. `mode` picks the branch and `amount` scales it, and
// both are four-byte writes to a push block — pressing a key does not compile
// anything and does not build a pipeline.
const POST = `
float3 tap(float2 uv)
{
    return scene.Sample(clamp(uv, float2(0.0), float2(1.0))).rgb;
}

float lum(float3 c)
{
    return dot(c, float3(0.2126, 0.7152, 0.0722));
}

float3 post(Post p)
{
    float2 texel = 1.0 / p.resolution;
    float2 uv = p.uv;
    float3 c = p.color;
    int m = int(mode + 0.5);

    if (m == 2)
    {
        // Chromatic aberration: the channels are sampled at three slightly
        // different radii, so the frame's edges fringe and its centre does not.
        // Scanlines on top, rolling with p.time.
        float2 dir = uv - 0.5;
        float k = 0.006 * amount;
        c.r = tap(uv - dir * k).r;
        c.g = tap(uv).g;
        c.b = tap(uv + dir * k).b;
        float scan = 0.90 + 0.10 * sin(uv.y * p.resolution.y * 1.4 + p.time * 9.0);
        c *= scan;
    }
    else if (m == 3)
    {
        // Bloom in one pass: twelve taps on two rings, each keeping only what
        // is over the threshold, added back on top. The orbs and the beams are
        // the only things bright enough to survive it, which is the point.
        float3 sum = float3(0.0);
        float r1 = 2.5 * amount;
        float r2 = 6.0 * amount;
        for (int i = 0; i < 6; i++)
        {
            float a = 6.2831853 * float(i) / 6.0;
            float2 d = float2(cos(a), sin(a));
            sum += max(tap(uv + d * texel * r1) - 0.55, float3(0.0));
            sum += max(tap(uv + d * texel * r2) - 0.55, float3(0.0));
        }
        c += sum * (0.30 * amount);
    }
    else if (m == 4)
    {
        // A ripple: the uv is pushed along its own radius by a travelling sine,
        // so the frame moves without anything in the scene moving.
        float r = length(uv - 0.5);
        float w = sin(r * 42.0 - p.time * 4.5) * 0.007 * amount;
        c = tap(uv + normalize(uv - 0.5 + float2(1e-5, 1e-5)) * w);
    }
    else if (m == 5)
    {
        // Toon: posterise the colour, then draw the edges a luminance gradient
        // finds. Five bands, and the outline is the difference between taps.
        float3 q = floor(c * 5.0 + 0.5) / 5.0;
        float lx = lum(tap(uv + float2(texel.x, 0.0))) - lum(tap(uv - float2(texel.x, 0.0)));
        float ly = lum(tap(uv + float2(0.0, texel.y))) - lum(tap(uv - float2(0.0, texel.y)));
        float e = clamp((abs(lx) + abs(ly)) * 5.0 * amount, 0.0, 1.0);
        c = lerp(q, float3(0.02, 0.02, 0.04), e);
    }

    // Every mode ends with the grade: a tint, a little more saturation, and a
    // vignette. Mode 1 is this and nothing else.
    c *= tint;
    c = lerp(float3(lum(c)), c, 1.0 + 0.30 * amount);
    float v = smoothstep(1.25, 0.30, length((uv - 0.5) * float2(1.0, 0.85)) * 1.7);
    c *= lerp(1.0, v, clamp(amount, 0.0, 1.0));
    return c;
}`;

// --------------------------------------------------------------- the state

// Each run_script call has its own scope, so anything the loop or a key handler
// needs to reach has to be kept somewhere that outlives the call.
const D = globalThis.demo = {
	scene, crates, panes, orbs, beams, dome,
	glowMat, domeMat, glassMat,
	source: POST,
	pass: null, mode: 0, amount: 1.0, spin: true, glow: true, glass: true, yaw: 14,
};

D.setMode = (m) => {
	D.mode = m;
	if (m === 0) { three.setPost(null); D.pass = null; return; }
	// The first press compiles; every press after it is a four-byte write. And
	// a press after `0` compiles again — off the disk cache, so it is quick.
	if (!D.pass) D.pass = three.setPost({ fragment: D.source, uniforms: { mode: m, amount: D.amount, tint: [1.06, 1.0, 0.94] } });
	else D.pass.uniforms.mode = m;
};

three.onKeyDown('0', () => D.setMode(0));
for (const k of ['1', '2', '3', '4', '5']) three.onKeyDown(k, (key) => D.setMode(Number(key)));
three.onKeyDown('space', () => D.setMode(D.mode >= 5 ? 1 : D.mode + 1));
three.onKeyDown(']', () => { D.amount = Math.min(2.5, D.amount + 0.25); if (D.pass) D.pass.uniforms.amount = D.amount; });
three.onKeyDown('[', () => { D.amount = Math.max(0.0, D.amount - 0.25); if (D.pass) D.pass.uniforms.amount = D.amount; });
three.onKeyDown('o', () => { D.spin = !D.spin; });
three.onKeyDown('g', () => {
	D.glow = !D.glow;
	for (const m of [...D.orbs, ...D.beams, D.dome]) m.visible = D.glow;
});
three.onKeyDown('t', () => {
	D.glass = !D.glass;
	for (const m of D.panes) m.visible = D.glass;
});

three.setAnimationLoop((t) => {
	const s = t / 1000;
	// Live uniform writes: no compile, no pipeline, once per frame.
	D.glowMat.uniforms.clock = s;
	D.domeMat.uniforms.clock = s;
	// The orbs breathe apart and back together, so the additive overlap opens
	// and closes and the white in the middle comes and goes.
	const spread = 1.35 + 0.35 * Math.sin(s * 0.6);
	D.orbs[0].position.x = -spread;
	D.orbs[1].position.x = spread;
	D.orbs[2].position.y = ORB_Y - 1.5 * (spread / 1.35);
	// A slow sweep rather than a full turn: the row is a comparison and it only
	// compares from the front. +/- 26 degrees is enough parallax to see the
	// crates move behind the glass.
	if (D.spin) {
		D.yaw = 14 + 26 * Math.sin(s * 0.12);
		three.camera.orbit(D.yaw);
	}
});

// Start on bloom, so the window opens with something on. The first compile is
// the only one that costs anything: measured here, 117 ms cold and 6 ms after
// `0` and back, which is the disk cache answering.
D.setMode(3);

three.camera.lookAt(0, 4.4, -6);
three.camera.orbit(12, 9, 34);

return {
	keys: {
		'1..5': 'post: grade, chroma+scanlines, bloom, ripple, toon',
		'0': 'post off',
		space: 'cycle the post modes',
		'[ ]': 'post amount down / up',
		o: 'auto-orbit', g: 'additive group', t: 'glass row',
	},
	row: 'left to right: additive panel, alpha 0.2/0.4/0.6/0.8/1.0, opaque panel — one crate behind each',
	stats: three.stats(),
};
