---
title: Creating materials
order: 2
summary: Textures, Slang shaders, uniform tables and a vertex stage — without splitting the draw call.
---

# Creating materials

A material is a **pipeline**. Two meshes sharing a geometry and a material are
one draw call; give them different materials and they are two. So most of the
work in this engine is getting many looks out of one material, and there are
three ways to do it: `mesh.color`, a uniform table with `mesh.variant`, and the
image the material samples.

```js
const scene = new three.Scene();
three.light.set([-0.5, -1, -0.35], 0.28);
```

## A picture on a shape

`MeshLambertMaterial` is the built-in shader with an image on it. It compiles
nothing and cannot fail with a shader diagnostic, so reach for it whenever what
you want is a picture on a surface.

There are no textures on disk here — the image below is arithmetic, which is
how every example in the repository works.

```js
function checkerTexture(size, a, b) {
	const px = new Uint8Array(size * size * 4);
	for (let y = 0; y < size; y++) {
		for (let x = 0; x < size; x++) {
			const c = ((x >> 3) + (y >> 3)) & 1 ? a : b;
			const i = (y * size + x) * 4;
			px[i] = c[0]; px[i + 1] = c[1]; px[i + 2] = c[2]; px[i + 3] = 255;
		}
	}
	return new three.DataTexture(px, size, size);
}

const floorMat = new three.MeshLambertMaterial({ map: checkerTexture(64, [70, 74, 82], [96, 101, 112]) });
floorMat.repeat = [12, 12];

const ground = new three.Mesh(new three.PlaneGeometry(36, 36), floorMat);
ground.rotation.x = -Math.PI / 2;
scene.add(ground);
```

`repeat` is on the **material**, not on the texture. That is the difference
that matters: one 36×36 plane showing 144 tiles is one mesh, where laying out
144 planes would be 144 of them. `offset` is the other half, and moving it
every frame scrolls the tiling without moving the geometry.

## A shader you write in the scene

A `ShaderMaterial` takes a Slang function — `float3 shade(Surface s)` — and
compiles it when you construct it, so a bad shader throws on that line with the
Slang diagnostic and the line number you wrote.

```js
const glow = new three.ShaderMaterial({
	uniforms: { tint: [0.3, 0.7, 1.0], t: 0 },
	fragment: `
		float3 shade(Surface s) {
			float pulse = 0.5 + 0.5 * sin(t * 2.0 + s.position.y * 1.5);
			float rim = pow(1.0 - abs(dot(s.normal, float3(0.0, 1.0, 0.0))), 2.0);
			return s.albedo * lambert(s.normal) + tint * (0.35 + pulse * 1.4) * (0.25 + rim);
		}
	`,
});
```

Every uniform is readable in the body **by its own name** — `tint` and `t`, not
`uniforms.tint`. `Surface` carries `albedo`, `normal`, `uv`, `position`,
`color`, `variant` and the material's own roughness and metalness, and five
helpers are already in scope: `standard(s)` is the whole built-in shading,
`lambert(normal)` is its diffuse half, `specular(s)` the other, plus
`srgb_to_linear` and `mapped_normal`.

> **There is no built-in clock.** `t` above is an ordinary uniform this script
> declared, and something has to write it. That is deliberate: a shader that
> reads its own time cannot be paused, scrubbed or stepped by the thing driving
> it. We wire it up at the bottom of this page.

## One material, many looks

A uniform written as an **array of arrays** is a table, and `mesh.variant` picks
the row. That is how one material — one pipeline, one draw call — gives many
meshes many looks. Note the shape: `[[...], [...]]` is a table, where a plain
`[0.3, 0.7, 1.0]` is a single vector uniform.

```js
const crystal = new three.ShaderMaterial({
	uniforms: {
		// One row per look: rgb, and how tight that row's rim light is.
		palette: [
			[0.95, 0.35, 0.30, 6],
			[0.40, 0.85, 0.50, 3],
			[0.45, 0.50, 0.95, 10],
			[0.95, 0.80, 0.35, 4],
		],
	},
	fragment: `
		float3 shade(Surface s) {
			float4 row = palette[s.variant];
			float rim = pow(1.0 - abs(s.normal.y), row.w);
			return row.rgb * lambert(s.normal) + row.rgb * rim * 0.6;
		}
	`,
});

const shard = new three.ConvexGeometry(
	Array.from({ length: 24 }, () => [three.randFloatSpread(1), three.randFloat(-0.4, 1.6), three.randFloatSpread(1)]),
);

for (let i = 0; i < 60; i++) {
	const rock = new three.Mesh(shard, crystal);
	// A ring, so the pool built further down has the middle to itself.
	const angle = (i / 60) * Math.PI * 2 + three.randFloatSpread(0.08);
	const radius = three.randFloat(11, 16);
	rock.position.set(Math.cos(angle) * radius, 0, Math.sin(angle) * radius);
	rock.rotation.y = three.randFloat(0, Math.PI * 2);
	rock.scale.setScalar(three.randFloat(0.6, 1.5));
	rock.variant = i % 4;          // the row of the table this copy wears
	scene.add(rock);
}
```

Sixty rocks, four looks, **one draw call**. `variant` is clamped to the table,
so an index past the end is the last row rather than an error. `randFloat` and
friends draw from a seeded stream `three.seed(n)` resets — they deliberately do
not use `Math.random`, because one `Math.random()` in the gameplay layer throws
away the determinism the fixed step exists for.

## Moving geometry without moving it

The other half of a `ShaderMaterial` is a vertex stage: `void displace(inout
Vertex v)`, run per vertex before anything is projected. No draw call, no
upload, no geometry change — the mesh is still the same asset and every copy of
it is still one call.

```js
const water = new three.ShaderMaterial({
	uniforms: { t: 0, deep: [0.06, 0.24, 0.38], shallow: [0.35, 0.75, 0.85] },
	bounds: 0.6,
	vertex: `
		void displace(inout Vertex v) {
			float wave = sin(v.local.x * 0.9 + t) * 0.18 + sin(v.local.y * 1.3 - t * 0.7) * 0.12;
			v.position.y += wave;
			v.uv += float2(wave * 0.05, 0.0);
		}
	`,
	fragment: `
		float3 shade(Surface s) {
			float depth = smoothstep(0.15, 0.55, s.position.y);
			return lerp(deep, shallow, depth) * lambert(s.normal);
		}
	`,
});

const pool = new three.Mesh(new three.PlaneGeometry(18, 18, 64, 64), water);
pool.rotation.x = -Math.PI / 2;
pool.position.y = 0.35;
scene.add(pool);
```

Three things to carry away:

- **`bounds` is not optional in practice.** Culling tests the mesh's
  *undisplaced* box, so geometry pushed outside it is dropped while still on
  screen. `bounds` is how many world units the vertex body can move by.
- **`v.local` is object space and is an input; `v.position` is world space and
  is what you write.** `v.index` is the vertex number, which makes a good
  per-vertex seed.
- **The vertex body and the fragment body compile into one Slang module**,
  vertex first. So a helper function may be declared in only one of them —
  declaring it in both is `error[E30201]: function already has a body`. Put
  shared helpers in `vertex` and call them from `fragment`.

## Drive the uniforms

```js
three.setAnimationLoop(() => {
	const t = three.clock.time;
	glow.uniforms.t = t;
	water.uniforms.t = t;
	floorMat.offset = [(t / 40) % 1, 0];
});

const orb = new three.Mesh(new three.SphereGeometry(1.4, 48, 24), glow);
orb.position.y = 3.2;
orb.color = [0.05, 0.07, 0.11, 1];   // s.albedo is this, so the glow term reads
scene.add(orb);

three.camera.lookAt(0, 1, 0);
three.camera.orbit(30, 22, 26);
three.debug.write(scene.stats());
```

`three.clock.time` is seconds from the game clock, so
`three.clock.timeScale = 0` freezes the shaders along with everything else —
which is exactly what a shader reading its own clock could not do.

Four materials, four draw calls, and the sixty rocks are one of them.

Next: [Loading a glTF kit](03-loading-a-gltf-kit.html) — meshes off disk, and
how to place them without guessing their size.
