// terrain.js — LayeredMaterial, which is glTF's CUSTOM_materials_layers
//
// Run it:
//
//     ./build/three --script examples/terrain.js
//     ./build/three --script examples/terrain.js --mcp   # and attach an agent to it
//
// or paste it into `run_script` against a `./build/three --mcp`.
//
// Once it is running: `1`, `2` and `3` toggle the three layers, `s` cycles the
// snow's blend mode, and `space` stops and starts the tide that fades the water
// in and out. Left alone the tide runs by itself.
//
// What it is here to show
// -----------------------
// **One mask image, three layers.** rock, grass and snow read the R, G and B
// channels of a single splat texture. That is the whole economy of the feature:
// four layers over one RGBA image is one sampler binding, and four separate
// greyscale masks would be four. The extension's per-layer `mask` channel is
// what makes it possible, and it is why a stack of three costs four bindings of
// the eight a material has rather than seven.
//
// **The detail tiles and the mask does not.** `uvScale: 12` on the rock lays its
// texture across the ground twelve times, while the splat map is sampled once
// over the whole surface — which is the difference between a terrain and a
// tartan. Both numbers are baked into the generated shader as literals, so they
// cost nothing at all.
//
// **Nothing costs push bytes unless it asks to.** Every tint, opacity, blend
// mode and uv scale here is compiled into the body as a constant; only the water
// says `animated: true`, and only the water can be faded from a frame callback.
// Print `ground.material.fragment` to see what was generated — it is ordinary
// Slang, and it is the first thing to read when a stack looks wrong.
//
// **The whole thing is one draw call.** A layer stack is a fragment function,
// not a pass: the four layers are four lerps in one shader over one mesh.

// -----------------------------------------------------------------------
// Textures. Generated rather than loaded so the file runs anywhere.

function splatMap(size) {
	// **Four layers in four channels, which is the whole point of the image.**
	// Grass in the low-middle, rock on the slopes, snow on the peaks, water in
	// the hollows. Each layer reads one component and knows nothing about the
	// others, so the four are one sampler binding rather than four.
	//
	// The bands overlap on purpose. A layer blends over what is under it rather
	// than replacing it, so the overlap is where the blend modes are visible —
	// bands that met at a hard edge would show nothing but the edge.
	const clamp = (v) => Math.max(0, Math.min(1, v));
	const px = new Uint8Array(size * size * 4);
	for (let y = 0; y < size; y++) {
		for (let x = 0; x < size; x++) {
			const u = x / size;
			const v = y / size;
			// A couple of ridges, plus some wobble so nothing is a straight line.
			const height = 0.5
				+ 0.30 * Math.sin(u * Math.PI * 1.7 + 0.4)
				+ 0.22 * Math.cos(v * Math.PI * 1.3)
				+ 0.08 * Math.sin(v * Math.PI * 5 + u * 7);
			const i = (y * size + x) * 4;
			px[i] = clamp((height - 0.42) * 3.0) * 255;                    // rock, on the slopes
			px[i + 1] = clamp(1.15 - Math.abs(height - 0.40) * 3.6) * 255; // grass, in the middle
			px[i + 2] = clamp((height - 0.78) * 6.0) * 255;                // snow, on the peaks
			// The fourth channel, and the reason the mask is RGBA rather than
			// RGB: water pools in the hollows, which is its own shape and not
			// the inverse of any of the three above.
			px[i + 3] = clamp((0.28 - height) * 5.0) * 255;
		}
	}
	// **Linear, and this is the line that matters most in the file.** A mask is
	// a weight rather than a colour, so through the default sRGB view the 0.5
	// that means "half" arrives as 0.21 and every layer comes out faint. It
	// reads as the blend modes being wrong and the image is fine.
	return new three.DataTexture(px, size, size, { colorSpace: three.LinearSRGBColorSpace });
}

function noise(size, base, spread, seed) {
	// A flat colour with per-texel grain, which is enough to see tiling.
	const px = new Uint8Array(size * size * 4);
	let s = seed;
	for (let i = 0; i < size * size; i++) {
		s = (s * 1103515245 + 12345) & 0x7fffffff;
		const n = (s / 0x7fffffff - 0.5) * spread;
		px[i * 4] = Math.max(0, Math.min(255, (base[0] + n) * 255));
		px[i * 4 + 1] = Math.max(0, Math.min(255, (base[1] + n) * 255));
		px[i * 4 + 2] = Math.max(0, Math.min(255, (base[2] + n) * 255));
		px[i * 4 + 3] = 255;
	}
	return new three.DataTexture(px, size, size);
}

// **The values are bright on purpose.** These are sRGB images, so the sampler
// decodes them on the way in: a mid-grey of 0.5 arrives at the shading maths as
// 0.21, and a palette picked to look right as numbers renders as a black field.
// Everything here is chosen against what it looks like after the decode.
const splat = splatMap(128);
const rock = noise(32, [0.62, 0.60, 0.57], 0.16, 7);
const grass = noise(32, [0.52, 0.68, 0.38], 0.14, 23);

// -----------------------------------------------------------------------
// The scene

const scene = new three.Scene();
scene.background = 0x8fb6d8;
three.light.set([0.4, 0.9, 0.35], 0.35);

// The description. A plain object, which is the same shape
// `asset.mesh(name).layers` hands back for a glTF authored with the extension —
// so this file and an imported terrain go through one constructor.
const stack = {
	// The base material. It is not a layer: it is what the layers sit on, and a
	// stack with every layer disabled renders exactly this.
	map: noise(32, [0.50, 0.44, 0.36], 0.10, 91),
	mask: splat,
	layers: [
		{
			name: 'rock',
			map: rock,
			mask: 'r',
			// Twelve repeats of the rock across the ground, and one of the mask.
			uvScale: 12,
		},
		{
			name: 'grass',
			map: grass,
			mask: 'g',
			uvScale: 16,
			// Overlay keeps the rock's grain showing through the grass rather
			// than painting over it, which is what makes the seam look like
			// ground instead of like a decal. Multiply would do the same job and
			// darken everything it touched; overlay preserves the value.
			blend: 'overlay',
			// A tint on the sampled image. Baked in, so it costs nothing.
			tint: [1.0, 1.1, 0.9],
		},
		{
			name: 'snow',
			mask: 'b',
			tint: [0.88, 0.91, 0.97],
			// No map: a layer may be a flat colour, and this one is. `mix`
			// rather than `screen` because screening white over a lit surface
			// blows it out — the mask already says where the snow is, so the
			// layer only has to be the colour of snow.
			blend: 'mix',
		},
		{
			name: 'water',
			// The tide, in the mask's fourth channel — its own shape rather than
			// the inverse of another layer's.
			mask: 'a',
			tint: [0.22, 0.42, 0.55],
			opacity: 0.0,
			// Mix, so the tide reads as water lying on the ground rather than as
			// the ground going dark.
			blend: 'mix',
			// **The only layer that spends push bytes.** One float4 of the
			// material's 52, which is what makes `.opacity` writable below.
			animated: true,
		},
	],
};

const ground = new three.Mesh(
	new three.PlaneGeometry(60, 60),
	new three.LayeredMaterial(stack),
);
ground.rotation.set(-Math.PI / 2, 0, 0);
scene.add(ground);

// Something to judge the scale and the lighting against.
const marker = new three.Mesh(
	new three.BoxGeometry(1.5, 3, 1.5),
	new three.MeshLambertMaterial({}),
);
marker.position.set(0, 1.5, 0);
marker.color = 0xd8d0c0;
scene.add(marker);

// The camera is a turntable rather than a free one — yaw, pitch and a distance
// from the point it looks at. See three.camera in the docs.
three.camera.lookAt(0, 1, 0);
three.camera.orbit(35, 28, 46);

console.log('generated shading body:\n' + ground.material.fragment);

// -----------------------------------------------------------------------
// The controls

const A = {
	tide: true,
	t: 0,
	// Radians a second, written as a period because that is the number anyone
	// reading it wants. It was 0.6 — ten and a half seconds in and out again —
	// and a tide that slow is not visibly a tide: a glance at the window shows a
	// still picture, and the one animated thing in the file reads as broken.
	tideRate: (2 * Math.PI) / 4,
	// Which blend mode the snow is on. Rebuilding the material is what changes
	// it, because a blend mode is compiled in — that is the trade the feature
	// makes, and cycling it here is the honest way to show the cost.
	snowModes: ['screen', 'mix', 'lighten', 'overlay'],
	snowAt: 0,

	rebuild() {
		const was = ground.material;
		ground.material = new three.LayeredMaterial(stack);
		// The old one holds a pipeline until nothing names it. Giving it back is
		// what stops an interactive session from compiling a shader per keypress
		// and keeping every one of them.
		was.dispose();
	},

	toggle(i) {
		stack.layers[i].enabled = stack.layers[i].enabled === false;
		A.rebuild();
		console.log(
			`${stack.layers[i].name} ${stack.layers[i].enabled === false ? 'off' : 'on'} — `
			+ `${ground.material.layers.length} layers`
		);
	},

	cycleSnow() {
		A.snowAt = (A.snowAt + 1) % A.snowModes.length;
		stack.layers[2].blend = A.snowModes[A.snowAt];
		A.rebuild();
		console.log('snow blend: ' + stack.layers[2].blend);
	},
};

three.onKeyDown('1', () => A.toggle(0));
three.onKeyDown('2', () => A.toggle(1));
three.onKeyDown('3', () => A.toggle(2));
three.onKeyDown('s', () => A.cycleSnow());
three.onKeyDown('space', () => {
	A.tide = !A.tide;
	console.log('tide ' + (A.tide ? 'running' : 'held'));
});

// Three.js's own name, and the argument is milliseconds since the host started
// counting rather than a delta.
three.setAnimationLoop((ms) => {
	if (!A.tide) return;
	A.t = ms / 1000;
	// The water is the last layer and the only animated one, so this is one
	// float4 written per frame and nothing rebuilt. Every other layer's numbers
	// are literals in the compiled body and could not be written from here even
	// if something wanted to — which is the trade, stated as a property.
	const water = ground.material.layers[ground.material.layers.length - 1];
	water.opacity = 0.5 + 0.5 * Math.sin(A.t * A.tideRate);
});
