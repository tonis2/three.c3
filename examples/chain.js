// chain.js — the post chain, one pass at a time, in one window
//
// Run it:
//
//     ./build/three --script examples/chain.js
//     ./build/three --script examples/chain.js --mcp   # and attach an agent
//
// or paste it into `run_script` against a `./build/three --mcp`.
//
// Keys once it is up:
//
//     1..4   how much of the chain runs: bright / +blurX / +blurY / +combine
//     r      the ×16 ÷16 round trip, which is the float intermediate on its own
//     0      post off  (setPost(null))
//     [ ]    blur radius down / up
//     - =    bloom intensity down / up
//     a      the animation on/off
//     o      auto-orbit on/off
//
// Attached with `--mcp`, the same verbs are on `demo`: `demo.build(2)`,
// `demo.roundTrip()`, `demo.radius = 12`, `demo.pass[0].uniforms.threshold`.
//
// What it is here to show
// -----------------------
// **Bloom is four passes and no graph.** `blur(bright(scene)) + scene` is the
// effect everybody reaches for a render graph to express, and here it is a list:
// one `setPost` and three `addPass`. Adjacency is the whole edge set, so the
// barriers between the passes are derived rather than declared, and there is
// nothing to name and no node to wire.
//
// **The one non-adjacent read is a binding, not an edge.** The fourth pass wants
// the picture as the geometry left it, three passes back, and no pass in between
// still has it. It reads `p.scene`, which is always image A. That is the single
// case a chain cannot express by adjacency, and it costs a sampler rather than a
// dependency solver — `plan.md` §13 has the argument.
//
// **The intermediate is float, and the bloom needs it to be.** The bright pass
// multiplies by `boost`, well above 1.0, and the blur that follows sees those
// values un-clamped: the chain images are `R16G16B16A16_SFLOAT`. Key `r`
// isolates that — a chain of ×16 then ÷16, which comes back to the untouched
// scene only because nothing in between clipped it. Swap the format to 8-bit
// sRGB and everything above 1/16 goes white, which is exactly what
// `three_tests::post` injects and counts.
//
// **`addPass` does not invalidate the handles you already hold.** The animation
// writes four uniforms across four passes every frame, through the four handles
// the four calls returned, and none of them has been re-fetched. A `setPost`
// would take them all away, because it replaces the whole chain — press `0` then
// `1` and the script rebuilds them, which is the only correct thing to do.
//
// **The whole animation is uniform writes.** Radius, boost and intensity are
// four bytes each into a push block. Nothing recompiles, no pipeline is built,
// and the chain never changes shape.

const scene = new three.Scene();

const floor = new three.Mesh(new three.BoxGeometry(20, 0.4, 20), new three.MeshLambertMaterial());
floor.position.set(0, -1.4, 0);
floor.color = 0x0e1116;
scene.add(floor);

// The emitters. These are what the bright pass keeps.
const LAMP_COLORS = [0xff3c14, 0x18c8ff, 0xffd23c];
const lamps = [];
for (let i = 0; i < 3; i++) {
	const m = new three.Mesh(new three.SphereGeometry(0.7, 32, 24), new three.MeshLambertMaterial());
	m.position.set((i - 1) * 3.0, 0.5, 0);
	m.color = LAMP_COLORS[i];
	scene.add(m);
	lamps.push(m);
}

// Dim geometry that must NOT bloom, so the threshold reads as a decision rather
// than as a brightness. These sit below it at every setting the keys reach.
for (let i = 0; i < 6; i++) {
	const t = new three.Mesh(new three.TorusGeometry(0.5, 0.15, 16, 48), new three.MeshLambertMaterial());
	t.position.set(-4.5 + i * 1.8, -0.7, 2.6);
	t.rotation.x = 1.2;
	t.color = 0x323d4d;
	scene.add(t);
}

three.camera.orbit(0, 12, 11);
three.camera.lookAt(0, 0, 0);

// ---------------------------------------------------------------------------
// The passes

// Keep only what is brighter than `threshold`, and push it well past 1.0. The
// multiply is the point: it is what the next pass has to be able to receive.
const BRIGHT = `
    float3 post(Post p) {
        float lum = dot(p.color, float3(0.2126, 0.7152, 0.0722));
        float over = max(lum - threshold, 0.0) / max(lum, 1e-4);
        return p.color * over * boost;
    }`;

// A separable Gaussian, so it is two passes rather than one — which is the
// reason a chain exists at all. `prev` is the sampler the pass before this one
// wrote; `p.color` is that same image at this pixel, and a blur needs the
// neighbours, so it samples by name and steps by `1.0 / p.resolution`.
const BLUR = (axis) => `
    float3 post(Post p) {
        float2 off = float2(${axis}) * radius / p.resolution;
        // 9-tap Gaussian folded into 5 linear-filtered samples.
        float3 sum  = prev.Sample(p.uv).rgb                    * 0.2270270270;
        sum += prev.Sample(p.uv + off * 1.3846153846).rgb * 0.3162162162;
        sum += prev.Sample(p.uv - off * 1.3846153846).rgb * 0.3162162162;
        sum += prev.Sample(p.uv + off * 3.2307692308).rgb * 0.0702702703;
        sum += prev.Sample(p.uv - off * 3.2307692308).rgb * 0.0702702703;
        return sum;
    }`;

// The non-adjacent read. `p.color` is the blurred extract from the pass before;
// `p.scene` is image A, three passes back and untouched by any of them.
const COMBINE = `
    float3 post(Post p) {
        return p.scene + p.color * intensity;
    }`;

// Everything the keys move, on one object, and on `globalThis.demo` so that an
// agent attached with `--mcp` can drive the same verbs a key does. `pass` is the
// handles in chain order; it is rebuilt whole whenever the length changes,
// because `setPost` is what starts a chain and it takes every old handle away.
const D = globalThis.demo = {
	pass: [],
	length: 0,
	radius: 6.0,
	intensity: 0.55,
	animating: true,
	orbiting: true,

	build(n) {
		D.length = n;
		D.pass = [];
		if (n === 0) { three.setPost(null); return D; }
		D.pass.push(three.setPost({ fragment: BRIGHT, uniforms: { threshold: 0.10, boost: 6.0 } }));
		if (n >= 2) D.pass.push(three.addPass({ fragment: BLUR('1.0, 0.0'), uniforms: { radius: D.radius } }));
		if (n >= 3) D.pass.push(three.addPass({ fragment: BLUR('0.0, 1.0'), uniforms: { radius: D.radius } }));
		if (n >= 4) D.pass.push(three.addPass({ fragment: COMBINE, uniforms: { intensity: D.intensity } }));
		return D;
	},

	// The float intermediate with nothing else in the way: pass 1 undoes pass 0
	// exactly, and the frame comes back as the geometry left it. It only does
	// that because what passed between them was a float image.
	roundTrip() {
		D.length = -1;
		D.pass = [];
		three.setPost({ fragment: `float3 post(Post p) { return p.color * 16.0; }` });
		three.addPass({ fragment: `float3 post(Post p) { return p.color / 16.0; }` });
		return D;
	},
};

D.build(4);

// ---------------------------------------------------------------------------
// The loop

for (const k of ['1', '2', '3', '4']) three.onKeyDown(k, (key) => D.build(Number(key)));
three.onKeyDown('0', () => D.build(0));
three.onKeyDown('r', () => D.roundTrip());
three.onKeyDown(']', () => { D.radius = Math.min(24.0, D.radius + 1.0); });
three.onKeyDown('[', () => { D.radius = Math.max(0.5, D.radius - 1.0); });
three.onKeyDown('=', () => { D.intensity = Math.min(2.0, D.intensity + 0.05); });
three.onKeyDown('-', () => { D.intensity = Math.max(0.0, D.intensity - 0.05); });
three.onKeyDown('a', () => { D.animating = !D.animating; });
three.onKeyDown('o', () => { D.orbiting = !D.orbiting; });

three.setAnimationLoop(() => {
	// The game clock, in seconds. Not the callback's argument divided by a
	// thousand: it is the same number, and this is the one that stops when
	// `three.clock.timeScale` does.
	const t = three.clock.time;

	// Four uniform writes across four passes, through the four handles the four
	// calls returned. Nothing here re-fetches a handle and nothing recompiles.
	if (D.length >= 1) {
		D.pass[0].uniforms.boost = D.animating
			? 4.0 + 3.5 * (0.5 + 0.5 * Math.sin(t * 1.1))
			: 6.0;
	}
	const r = D.animating ? D.radius * (0.6 + 0.6 * (0.5 + 0.5 * Math.sin(t * 0.7))) : D.radius;
	if (D.length >= 2) D.pass[1].uniforms.radius = r;
	if (D.length >= 3) D.pass[2].uniforms.radius = r;
	if (D.length >= 4) {
		D.pass[3].uniforms.intensity = D.animating
			? D.intensity * (0.7 + 0.6 * (0.5 + 0.5 * Math.sin(t * 0.5)))
			: D.intensity;
	}

	if (D.animating) {
		for (let i = 0; i < lamps.length; i++) {
			lamps[i].position.y = 0.5 + 0.45 * Math.sin(t * 1.4 + i * 2.1);
		}
	}
	if (D.orbiting) three.camera.orbit(18 * Math.sin(t * 0.25), 12, 11);
});
