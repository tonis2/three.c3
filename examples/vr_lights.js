// vr_lights.js — a heavier VR scene for measuring: vr_hello's cubes with 32
// moving lamps and ambient occlusion on, so light clustering and AO both cost.
//
//   ./build/three --script examples/vr_lights.js
//   packaging/android/build-apk.sh examples/vr_lights.js --run
//
// Both eyes should look the same: lamp pools on the floor and dark creases
// where the cubes meet it.

const scene = new three.Scene();
scene.background = 0x05060a;
three.light.set([-0.4, -1, -0.25], 0.08);
three.light.occlusion = { enabled: true, radius: 0.6, intensity: 1, bias: 0.02 };

const matte = new three.MeshLambertMaterial({});

const floor = new three.Mesh(new three.PlaneGeometry(20, 20), matte);
floor.rotation.x = -Math.PI / 2;
floor.color = [0.5, 0.5, 0.52];
scene.add(floor);

const cube = new three.BoxGeometry(1, 1, 1);
for (let i = 0; i < 12; i++) {
	const a = (i / 12) * Math.PI * 2;
	const r = i % 2 ? 4 : 2.5;
	const box = new three.Mesh(cube, matte);
	box.position.set(Math.sin(a) * r, 0.5, -Math.cos(a) * r);
	box.rotation.y = -a;
	box.color = [0.8, 0.78, 0.74];
	scene.add(box);
}

const LAMPS = 32;
const lamps = [];
for (let i = 0; i < LAMPS; i++) {
	const hue = i / LAMPS;
	const color = [0.5 + 0.5 * Math.cos(6.283 * hue), 0.5 + 0.5 * Math.cos(6.283 * (hue - 0.33)),
		0.5 + 0.5 * Math.cos(6.283 * (hue - 0.67))];
	const hex = (Math.round(color[0] * 255) << 16) | (Math.round(color[1] * 255) << 8) | Math.round(color[2] * 255);
	lamps.push(three.lights.add({ position: [0, 0.6, 0], range: 2.5, color: hex, intensity: 3 }));
}

// Standing at the origin, looking down -Z, first person.
three.camera.lookAt(0, 0, 0);
three.camera.orbit(0, 0, 0);

three.setAnimationLoop((ms) => {
	const t = ms / 1000;
	for (let i = 0; i < LAMPS; i++) {
		const a = (i / LAMPS) * Math.PI * 2 + t * (i % 2 ? 0.3 : -0.2);
		const r = 1.5 + 4 * ((i * 7) % LAMPS) / LAMPS;
		lamps[i].position = [Math.sin(a) * r, 0.4 + 0.3 * Math.sin(t + i), -Math.cos(a) * r];
	}
});

console.log(`vr_lights: ${JSON.stringify(scene.stats())}`);
