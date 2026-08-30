---
title: Creating materials
order: 2
summary: Textures, Slang shaders, uniform tables and a vertex stage — without splitting the draw call.
---

# Creating materials

A material is a **pipeline**. Two meshes that share a geometry and a material
are one draw call; give them different materials and they become two. So most
of the work in this engine is getting many looks out of one material. There
are three ways to do that: `mesh.color`, a uniform table picked by
`mesh.variant`, and the image the material samples.

```js
const scene = new three.Scene();
three.light.set([-0.5, -1, -0.35], 0.28);
```

## A picture on a shape

`MeshLambertMaterial` is the built-in shader that draws an image on a surface.
It compiles nothing, so it can never fail with a shader error. Use it whenever
all you need is a picture on a shape.

This tutorial uses no texture files on disk. The image below is generated with
arithmetic, which is how every example in the repository works.

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

`repeat` lives on the **material**, not on the texture. This is the difference
that matters: one 36×36 plane showing 144 tiles is one mesh, while laying out
144 separate planes would be 144 meshes. `offset` is the other half — change it
every frame and the tiling scrolls without the geometry moving.

## A shader you write in the scene

A `ShaderMaterial` takes a Slang function, `float3 shade(Surface s)`, and
compiles it when you construct the material. If the shader has a mistake, the
constructor throws on that line with the Slang error message and the line
number from your code.

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

Every uniform is available in the shader body **by its own name** — `tint` and
`t`, not `uniforms.tint`. `Surface` carries `albedo`, `normal`, `uv`,
`position`, `color`, `variant`, and the material's own roughness and metalness.
Five helper functions are already in scope: `standard(s)` is the complete
built-in shading, `lambert(normal)` is its diffuse part, `specular(s)` is the
rest, plus `srgb_to_linear` and `mapped_normal`.

> **There is no built-in clock.** `t` above is an ordinary uniform that this
> script declared, and something has to write to it. That is deliberate: a
> shader that reads its own time cannot be paused, scrubbed or stepped by
> whatever is driving it. We wire it up at the bottom of this page.

## One material, many looks

A uniform written as an **array of arrays** is a table, and `mesh.variant`
picks a row from it. This is how one material — one pipeline, one draw call —
gives many meshes many different looks. Note the shape: `[[...], [...]]` is a
table, while a plain `[0.3, 0.7, 1.0]` is a single vector uniform.

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
	rock.variant = i % 4;          // the row of the table this copy uses
	scene.add(rock);
}
```

Sixty rocks, four looks, **one draw call**. `variant` is clamped to the table,
so an index past the end gives you the last row instead of an error.

`randFloat` and its relatives draw from a seeded random stream, which
`three.seed(n)` resets. They deliberately do not use `Math.random`: a single
`Math.random()` call in the gameplay layer throws away the determinism that the
fixed timestep exists to provide.

## Moving geometry without moving it

The other half of a `ShaderMaterial` is a vertex stage:
`void displace(inout Vertex v)`, which runs once per vertex before anything is
projected onto the screen. No extra draw call, no upload, no change to the
geometry — the mesh is still the same asset, and every copy of it is still one
draw call.

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

Three things to remember:

- **`bounds` is not optional in practice.** Culling checks the mesh's
  *undisplaced* bounding box, so geometry pushed outside that box is skipped
  even while it is still on screen. `bounds` is how many world units the
  vertex stage is allowed to move things.
- **`v.local` is object space and is an input. `v.position` is world space
  and is what you write to.** `v.index` is the vertex number, which makes a
  good per-vertex random seed.
- **The vertex body and the fragment body compile into one Slang module**,
  vertex first. So a helper function may be declared in only one of them —
  declaring it in both gives `error[E30201]: function already has a body`.
  Put shared helpers in `vertex` and call them from `fragment`.

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

`three.clock.time` is the game clock in seconds. Setting
`three.clock.timeScale = 0` freezes the shaders along with everything else —
exactly what a shader reading its own clock could not do.

Four materials, four draw calls, and the sixty rocks are one of them.

Next: [Loading a glTF kit](03-loading-a-gltf-kit.html) — meshes off disk, and
how to place them without guessing their size.
