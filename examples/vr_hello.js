// vr_hello.js — the first scene for the Quest build: things at known sizes and
// distances, so scale and tracking are easy to judge with the headset on.
//
//   ./build/three --script examples/vr_hello.js
//   packaging/android/build-apk.sh examples/vr_hello.js --run
//
// Every cube is 1 m. You stand at the origin facing -Z: one cube 2 m ahead on
// the floor, a ring of eight 4 m out, and a ball turning at head height.
// In VR the camera's target and yaw are where the player stands and faces.

const scene = new three.Scene();
scene.background = 0x0b0e14;
three.light.set([-0.4, -1, -0.25], 0.45);

const matte = new three.MeshLambertMaterial({});

const floor = new three.Mesh(new three.PlaneGeometry(20, 20), matte);
floor.rotation.x = -Math.PI / 2;
floor.color = [0.14, 0.15, 0.19];
scene.add(floor);

const grid = new three.GridHelper(20, 20, 0x3a4256);
grid.position.y = 0.002;
scene.add(grid);

const cube = new three.BoxGeometry(1, 1, 1);

const ahead = new three.Mesh(cube, matte);
ahead.position.set(0, 0.5, -2);
ahead.color = [0.85, 0.45, 0.2];
scene.add(ahead);

for (let i = 0; i < 8; i++) {
	const a = (i / 8) * Math.PI * 2;
	const ring = new three.Mesh(cube, matte);
	ring.position.set(Math.sin(a) * 4, 0.5, -Math.cos(a) * 4);
	ring.rotation.y = -a;
	ring.color = [0.25 + 0.6 * (i / 8), 0.4, 0.85 - 0.5 * (i / 8)];
	scene.add(ring);
}

const ball = new three.Mesh(new three.SphereGeometry(0.25, 32, 16), matte);
ball.position.set(0, 1.5, -2.5);
ball.color = [0.95, 0.9, 0.55];
scene.add(ball);

// Standing at the origin, looking down -Z, first person.
three.camera.lookAt(0, 0, 0);
three.camera.orbit(0, 0, 0);

three.setAnimationLoop((ms) => {
	const t = ms / 1000;
	ball.position.x = Math.sin(t * 0.8) * 1.2;
	ball.position.y = 1.5 + Math.sin(t * 1.7) * 0.2;
	ahead.rotation.y = t * 0.5;
});

console.log(`vr_hello: ${JSON.stringify(scene.stats())}`);
