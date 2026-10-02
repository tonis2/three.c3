// Parallax occlusion mapping on the built-in material: the same brick floor
// three times - flat, marched, and marched with the relief shading itself.
//
//   ./build/three --script examples/parallax.js --screenshot parallax.png
//

const SIZE = 256; // the texture, square
const ROWS = 4; // brick courses per tile
const MORTAR = 6; // mortar width, in texels

// One brick course is SIZE/ROWS tall and two bricks wide, every other course
// offset by half a brick. Height: the brick face sits at 0.85 with a bevel down
// to the mortar at 0.1. Colour: a dusty red per brick, grey mortar.
function bricks() {
	const height = new Uint8Array(SIZE * SIZE * 4);
	const color = new Uint8Array(SIZE * SIZE * 4);
	const course = SIZE / ROWS;
	const brick = SIZE / 2;
	for (let y = 0; y < SIZE; y++) {
		const row = Math.floor(y / course);
		const shift = row % 2 === 0 ? 0 : brick / 2;
		for (let x = 0; x < SIZE; x++) {
			const bx = (x + shift) % brick;
			const by = y % course;
			// Distance to the nearest mortar line, in texels.
			const edge = Math.min(bx, brick - bx, by, course - by);
			const face = Math.min(Math.max((edge - MORTAR / 2) / 6, 0), 1);
			const h = 0.1 + 0.75 * face;
			const id = row * 7 + Math.floor(((x + shift) % SIZE) / brick) * 13;
			const tint = 0.8 + 0.2 * Math.sin(id * 12.9898);
			const i = (y * SIZE + x) * 4;
			const v = Math.round(h * 255);
			height[i] = v; height[i + 1] = v; height[i + 2] = v; height[i + 3] = 255;
			const mortar = face < 0.5;
			color[i] = mortar ? 120 : Math.round(150 * tint);
			color[i + 1] = mortar ? 116 : Math.round(70 * tint);
			color[i + 2] = mortar ? 108 : Math.round(55 * tint);
			color[i + 3] = 255;
		}
	}
	return {
		height: new three.DataTexture(height, SIZE, SIZE, { colorSpace: three.LinearSRGBColorSpace }),
		color: new three.DataTexture(color, SIZE, SIZE),
	};
}

const scene = new three.Scene();
three.light.set([0.6, 0.35, 0.7], 0.25);

const { height, color } = bricks();
const floor = (x, options) => {
	const material = new three.MeshLambertMaterial({ map: color, roughness: 0.85, ...options });
	material.repeat = [2, 2];
	const mesh = new three.Mesh(new three.PlaneGeometry(2.2, 4), material);
	mesh.rotation.x = -Math.PI / 2;
	mesh.position.set(x, 0, 0);
	scene.add(mesh);
	return material;
};

floor(-2.4, {});
floor(0, { heightMap: height, heightScale: 0.06, parallaxSteps: 24 });
floor(2.4, { heightMap: height, heightScale: 0.06, parallaxSteps: 24, parallaxShadow: 1 });

three.camera.lookAt(0, 0, 0);
three.camera.orbit(0, 22, 6.5);
