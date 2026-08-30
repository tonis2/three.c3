# Example

```js
const scene = new three.Scene();

// One geometry per mesh is fine — the same numbers are the same asset,
// so this whole grid is a single instanced draw call.
for (let x = -4; x <= 4; x++) {
  for (let z = -4; z <= 4; z++) {
    const cube = new three.Mesh(new three.BoxGeometry(1, 1, 1));
    cube.position.set(x * 1.5, 0, z * 1.5);
    cube.scale.y = 1 + Math.abs(x + z) * 0.4;   // scale is free, a new size is not
    scene.add(cube);
  }
}

const ball = new three.Mesh(
  new three.SphereGeometry(1.2, 48, 24),
  new three.ShaderMaterial({
    uniforms: { tint: [1, 0.4, 0.2] },
    fragment: "float3 shade(Surface s) { return lambert(s.normal) * tint; }",
  }),
);
ball.position.y = 3;
scene.add(ball);

three.camera.frameAll();
three.render(scene, three.camera);
three.debug.write(scene.stats());   // { drawCalls: 2, uniqueMeshes: 2, instances: 82, ... }
```

# Example, from a file

```js
const kit = three.load("assets/kit.glb");
const wall = kit.mesh("wall_corner_02");
const scene = new three.Scene();
for (let i = 0; i < 12; i++) {
  const m = new three.Mesh(wall);
  m.position.set(i * 2, 0, 0);
  m.rotation.y = Math.PI / 2;
  scene.add(m);
}
three.camera.frameAll();
three.render(scene, three.camera);
three.debug.write(scene.stats());   // { drawCalls: 1, instances: 12, ... }
```
