// storage_images.js — compute shaders writing images: a floor painted by a
// kernel every frame, and a post chain that measures the frame and exposes it.
//
//   ./build/three --script examples/storage_images.js
//   ./build/three --headless --script examples/storage_images.js --frames 90 --screenshot /tmp/storage.png
//
// Three things here that a fragment shader cannot do on its own:
//
//   - `three.compute.image` — the floor's texture is an image a kernel rewrites
//     every frame, and the material samples it like any other texture.
//   - a side pass — the first post pass writes no frame at all, only a 64-bucket
//     histogram of the frame's brightness, with `InterlockedAdd` into an r32ui
//     image that is cleared every frame.
//   - an image that persists — the second pass reduces the histogram to one
//     exposure and eases towards it, so it keeps last frame's answer in an r32f
//     image the size of one texel.
//
// The last pass applies the exposure and a horizontal glow whose taps come out
// of workgroup memory: each texel is loaded once and read by nine threads.

const scene = new three.Scene();
scene.background = 0x020308;

three.light.set([0.4, 1, 0.3], 0.6);
three.lights.add({ position: [0, 2.5, 0], range: 12, color: 0xffb070, intensity: 18 });

// -- the floor: a texture a kernel writes -------------------------------------

const SIZE = 256;
const paint = three.compute.image({ width: SIZE, height: SIZE, format: 'rgba8' });
const ripple = three.compute.kernel(`
image2d<rgba8> paint;

struct Push @pushconstant { float time; }
Push push;

struct ComputeIn { uint3 id @builtin(global_invocation_id); }

fn void main(ComputeIn at) @compute @threads(8, 8, 1)
{
	int2 px = int2(at.id.xy);
	float2 uv = (float2(px) + 0.5) / ${SIZE}.0 - 0.5;
	float ring = 0.5 + 0.5 * sin(length(uv) * 60.0 - push.time * 3.0);
	paint[px] = float4(0.08 + 0.35 * ring, 0.12 + 0.2 * ring, 0.3 + 0.25 * ring, 1.0);
}`, { name: 'ripple' });

const floor = new three.Mesh(new three.PlaneGeometry(16, 16), new three.MeshLambertMaterial({ map: paint }));
floor.rotation.x = -Math.PI / 2;
scene.add(floor);

// Something bright enough to glow and to pull the exposure down when it is in view.
const lamp = new three.Mesh(new three.SphereGeometry(0.4, 24, 16), new three.MeshLambertMaterial());
lamp.material.emissive = 0xffc890;
lamp.material.emissiveIntensity = 6;
lamp.position.set(0, 2.5, 0);
scene.add(lamp);

for (let i = 0; i < 6; i++) {
	const box = new three.Mesh(new three.BoxGeometry(1, 1 + i * 0.3, 1));
	const a = (i / 6) * Math.PI * 2;
	box.position.set(Math.cos(a) * 4, (1 + i * 0.3) / 2, Math.sin(a) * 4);
	box.color = [0.5 + 0.08 * i, 0.4, 0.35];
	scene.add(box);
}

three.camera.lookAt(0, 1, 0);
three.camera.orbit(0.6, 0.35, 11);

// -- the post chain ------------------------------------------------------------

// Shared by name between the passes that declare it: one image, two readers.
const histogram = { format: 'r32ui', size: [64, 1], clear: 'frame' };
const exposure = { format: 'r32f', size: [1, 1] };

// 1. A side pass: no `output`, only the histogram. Log2 luminance from 2^-10
//    to 2^6 across 64 buckets.
three.setPost({
	compute: `
fn void main(PostThread t) @compute @threads(16, 16, 1)
{
	int2 px = int2(t.id.xy);
	if (!inside(px)) return;
	float lum = dot(color_at(px), float3(0.2126, 0.7152, 0.0722));
	float at = clamp((log2(max(lum, 0.00001)) + 10.0) / 16.0, 0.0, 1.0);
	InterlockedAdd(histogram[int2(int(at * 63.0), 0)], 1u);
}`,
	images: { histogram },
});

// 2. One thread: the histogram's mean log luminance, and an exposure that puts
//    it at middle grey, eased towards so a bright lamp swinging into view does
//    not snap the frame.
const adapt = three.addPass({
	compute: `
fn void main(PostThread t) @compute @threads(1, 1, 1)
{
	float total = 0.0;
	float weighted = 0.0;
	for (int i = 1; i < 64; i++)
	{
		float n = float(histogram[int2(i, 0)]);
		total += n;
		weighted += n * (float(i) / 63.0 * 16.0 - 10.0);
	}
	float average = total > 0.0 ? exp2(weighted / total) : 0.18;
	float target = clamp(0.18 / average, 0.05, 8.0);
	float current = exposure[int2(0, 0)];
	exposure[int2(0, 0)] = current <= 0.0 ? target : lerp(current, target, uniforms().speed);
}`,
	images: { histogram, exposure },
	threads: [1, 1],
	uniforms: { speed: 0.06 },
});

// 3. The exposure applied, and a horizontal glow over what it pushes past 1.
//    A workgroup is one 64-pixel run of a row: it loads that run plus four
//    pixels either side into `row` once, and each thread sums nine of them.
const finish = three.addPass({
	compute: `
shared float3 row[72];

fn void main(PostThread t) @compute @threads(64, 1, 1)
{
	int2 px = int2(t.id.xy);
	int last = int(resolution().x) - 1;
	int start = int(t.group.x) * 64 - 4;
	float e = exposure[int2(0, 0)];
	for (uint k = t.local.x; k < 72u; k += 64u)
	{
		float3 c = color_at(int2(clamp(start + int(k), 0, last), px.y)) * e;
		row[k] = max(c - float3(1.0), float3(0.0));
	}
	barrier();
	if (!inside(px)) return;
	float3 glow = float3(0.0);
	for (uint k = 0u; k < 9u; k++) glow += row[t.local.x + k];
	output[px] = float4(color_at(px) * e + glow * (uniforms().glow / 9.0), 1.0);
}`,
	images: { exposure },
	uniforms: { glow: 0.8 },
});

three.toneMapping = 'agx';

// -- the frame -----------------------------------------------------------------

three.setAnimationLoop((ms) => {
	const t = ms / 1000;
	ripple.dispatch({ paint }, { threads: [SIZE, SIZE], push: { time: t } });
	// Sent without waiting: the frame that samples the floor is ordered after it
	// on the queue, and the CPU goes on to draw it.
	three.compute.submitAsync();
	lamp.position.x = Math.sin(t * 0.7) * 3;
	three.render(scene, three.camera);
});

console.log(`storage images: floor ${paint}, post chain of ${finish.index + 1} passes, `
	+ `exposure easing at ${adapt.uniforms.speed}`);
