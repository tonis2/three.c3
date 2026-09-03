# Classes

## Scene

```js
new three.Scene()
```

An independent world, made and immediately shown. It does not empty or free the scene before it:
that one keeps its objects, its bodies and its nav bake until you call `dispose()` on it. That is
what lets you build the next level while the current one is still on screen — see the many-scenes
topic. It is an Object3D, so moving it moves everything.

### Properties

- `position`
- `rotation`
- `scale`
- `visible`
- `name`
- `children`
- `parent`
- `animations`
- `isActive` — whether this is the one being rendered; only one is, and only that one is stepped,
  drawn and queried
- `id` — the host's id for this scene, what `three.sceneById(id)` takes. Read-only
- `physics` — this scene's own physics world; `three.physics` is whichever scene is active
- `nav` — this scene's own navigation bake; `three.nav` is whichever scene is active
- `static` — marks the whole scene as not moving again — see the static-casters topic
- `background` — the clear colour: `[r,g,b]`, `0x87ceeb`, null for the default, or an equirectangular
  Texture, which draws as a sky. This scene's own, so setting it on a scene that is not being
  rendered paints nothing until you activate it
- `environment` — an equirectangular Texture surfaces reflect, or null. This is what makes
  `material.metalness` mean something: a metal reflects and does not scatter, so with nothing around
  it, it renders dark. Separate from `background`, as it is in Three.js. `material.roughness` picks a
  mip of this image, so a rough metal reflects a blurred sky
- `backgroundIntensity` — a multiplier on the backdrop, default 1
- `environmentIntensity` — a multiplier on what the scene reflects, default 1; 0 turns the reflection
  off without giving the image back
- `environmentRotation` — radians about world Y. One number that turns both the backdrop and the
  reflections; Three.js has two, and a metal reflecting a sky pointing elsewhere than the one on
  screen is a bug rather than a feature
<!-- three.light and three.lights rather than scene properties, even though their values
     travel with the scene: they are the active scene's, and listing them here would suggest a
     scene that is not on screen could be lit through them. -->
- `collides` — on the root, which draws nothing; set it on the meshes

### Methods

- `add(...objects)`
- `remove(...objects)`
- `traverse(fn)`
- `getObjectByName(name)`
- `stats()`
- `activate()`
- `dispose()`
- `unload()`
- `export(path)`
- `pick(x, y)`
- `raycast(origin, direction)`
- `getWorldPosition()`
- `boundingBox()`
- `boundsInParent()`
- `align(axis, edge, at)`
- `snapTo(other, side, axes)` — this piece on one side of that one, touching, or on a marker name
  both pieces carry
- `alignTo(other, axes)` — flush without touching
- `row(axis, pieces, opts)` — N pieces edge to edge along one axis
- `play(name, { loop, speed, time, fade })`
- `stop()`
- `socket(bone)`
- `toJSON()`

### Details

#### isActive

Whether this is the Scene being rendered. Exactly one is.

A scene that is not active is drawn by nothing, stepped by nothing and queried by nothing — which is
what makes building the next level while the current one runs cost the frame nothing, and also why
bodies you add to it stand still until you activate it.

#### activate

Show this Scene, and stop showing whichever one was.

Nothing is freed: the scene being left keeps its objects, its bodies and its bake, so activating it
again brings the world back exactly as it was — its background, its light and its shadow settings
included.

The one thing that does not come back is the camera's attachment: the follow named an object in the
scene being left, so it is dropped and `three.camera.follow` is yours to set again.

#### dispose

Free this Scene and everything in it: its nodes, its physics bodies, its nav bake, and the asset
references its meshes held.

What is actually reclaimed depends on what else holds those assets — two scenes over one kit means
disposing either frees nothing, which is right. Follow it with `three.unloadUnused()`.

The Scene being rendered cannot be disposed; activate another one first, because a frame with no
scene to draw is a black window that reads as a renderer fault.

## Mesh

```js
new three.Mesh(geometry, material)
```

`geometry` is a generated shape (`new three.BoxGeometry(1, 1, 1)`) or a reference from
`asset.mesh(name)` / `asset.meshAt(i)`. `material` is optional. N meshes sharing one geometry and one
material is one draw call.

### Properties

- `position`
- `rotation`
- `scale`
- `visible`
- `name`
- `geometry`
- `material`
- `children`
- `parent`
- `color` — per copy, free: `[r,g,b]`, `[r,g,b,a]` or `0xff8800`
- `variant` — per copy, free: which row of the material's table
- `static` — this will not move again: drawn into the shadow map once and kept
- `collides` — false takes it out of every spatial query — scenery, not a wall
- `animations` — empty unless this came from `asset.instantiate()`
- `morphs` — how many morph targets the geometry has, 0 for most
- `weights` — per copy, free: how much of each morph target this one wears

### Methods

- `add(...)`
- `remove(...)`
- `traverse(fn)`
- `getObjectByName(name)`
- `getWorldPosition()`
- `boundingBox()`
- `boundsInParent()`
- `align(axis, edge, at)`
- `snapTo(other, side, axes)` — this piece on one side of that one, touching, or on a marker name
  both pieces carry
- `alignTo(other, axes)` — flush without touching
- `row(axis, pieces, opts)` — N pieces edge to edge along one axis
- `play(name, opts)`
- `stop()`
- `socket(bone)`
- `toJSON()`

## MorphTargets

```js
mesh.weights — on a geometry that has any
```

Blend shapes. A glTF morph target is a displacement of every vertex, and `mesh.weights` is how much
of each one this copy wears; `mesh.morphs` is how many the geometry has, 0 for anything that is not a
blend-shape mesh.

Write `mesh.weights[1] = 0.5` or `mesh.weights = [0.5, 0]` — a shorter array leaves the rest where
they are, so setting one expression on a twenty-target face is one call. Weights outside 0..1 are
allowed and exaggerate; glTF does not clamp them either.

Addressed by index, not by name: glTF puts target names in `mesh.extras.targetNames`, which is a
convention rather than a required field.

Per copy and free, like `color` and `variant`: the displacements live on the asset and only a handful
of floats per copy do not, so two faces built from one head mesh wear different expressions and stay
one draw call. An all-zero vector takes the copy off the morph path entirely.

A file that animates its weights just works: `play()` drives them like any other channel, and a
crossfade blends them. Morph runs before skinning, so a rigged face morphs and then poses, which is
the order glTF specifies.

### Properties

- `length` — the target count

### Methods

- `set(values)`
- `fill(v)`
- `toArray()`

## Material

```js
not constructed — it is what MeshLambertMaterial and ShaderMaterial share
```

The base both materials extend, exported for `instanceof` and for the properties they have in common.
`mesh.material` accepts anything that is one.

Assigning a material to a helper throws whatever kind it is: a helper draws line pairs and every
pipeline you can build draws triangles.

### Properties

- `map` — a `three.texture`, or null; wins over whatever image the mesh itself carries
- `side` — `three.FrontSide`, `three.BackSide` or `three.DoubleSide`
- `transparent` — whether it blends; derived from `blending`, and read-only
- `blending` — `three.NoBlending`, `three.NormalBlending` or `three.AdditiveBlending`
- `opacity` — 0 to 1, settable and free
- `roughness` — 0 to 1, 1 by default: how spread out the highlight is
- `metalness` — 0 to 1, 0 by default: a metal has no diffuse
- `reflectance` — 0 to 1, 0 by default: how strongly a non-metal reflects, and the switch that turns
  the specular term on at all
- `repeat` — `[u, v]`, or one number for both: how many times the map is laid across the surface
- `offset` — `[u, v]`: where the map starts, in whole repeats
- `uvVariants` — up to eight `[offsetU, offsetV, turns, flip]` rows, one uv transform per copy, picked by `mesh.variant`; `null` clears it
- `stochastic` — sample this material's maps so a tiled surface stops having a period; for a texture with no structure in it
- `alive` — false once `dispose()` has been called on it

### Methods

- `dispose()`
- `toJSON()`

### Details

#### blending

Decided at construction and not settable. This device bakes blending into the pipeline, so a change
is a new material — which is one line.

`NormalBlending` is what `{ transparent: true }` means and is what glass, water and a foliage card
want. `AdditiveBlending` never darkens what is behind it and is what fire, a glow and a beam want.

#### opacity

It rides the push block, so writing it costs nothing.

It does nothing unless the material was built transparent, because an opaque pipeline discards the
alpha. That is the hardware's answer, and Three.js behaves the same way.

#### roughness

1 is perfectly diffuse, and is what every material here was before there was a specular term.

#### metalness

A metal's colour moves out of the diffuse and into the highlight. With no environment map to reflect,
a fully metallic surface is its highlights and the ambient floor and nothing else — which is correct,
and is dark.

#### reflectance

0.5 is the 4% that ordinary dielectrics reflect — use it for anything wet, polished or glazed.

A name Three.js does not have, because Three.js defaults every material to having a highlight and
this one defaults to none.

#### repeat

1 by default; zero throws, because it maps the whole surface onto one texel.

Without it a surface maps its texture exactly once, so texel density is a function of how big the
mesh is and a 128px image across 100 units is a smear.

It is on the material rather than on the texture as in Three.js: textures here are deduplicated by
content across every file, so a transform on the texture would change every unrelated surface using
the same picture. Two densities of one image is two materials.

## DataTexture

```js
new three.DataTexture(data, width, height, { colorSpace, generateMipmaps })
```

Pixels a script built, uploaded as a texture.

`data` is a Uint8Array (or a plain Array, which is copied) of `width*height*4` bytes in r, g, b, a
order, row-major from the bottom-left corner — uv (0,0) is bottom-left, as in Three.js. RGBA8 only,
and it is on the device when the constructor returns: there is no `needsUpdate` and nothing to
schedule.

Deduplicated against every other texture by content, so generated pixels and the identical `.png` are
one upload. It is a Texture in every other way. Generating 256x256 in JavaScript costs about 16 ms
before any of this, so build at load rather than per frame. `path` is null; the side limit is 8192.

The fourth argument is the same options object `three.texture` takes, and both options matter more
here: generated pixels are as often a table indexed exactly — a palette, a ramp, a lookup a shader
reads — as a picture, and a table wants
`{ colorSpace: three.LinearSRGBColorSpace, generateMipmaps: false }`, because its channels are
numbers and a blurred mip level of a lookup approximates nothing.

### Properties

- `width`
- `height`
- `path` — null
- `alive`
- `colorSpace` — `'srgb'` or `'srgb-linear'`; fixed at upload
- `levels` — how many mip levels it got
- `generateMipmaps` — whether it got a chain — the answer, not the request

### Methods

- `read(into)`
- `dispose()`
- `toJSON()`
- `toString()`

## Texture

```js
three.texture(path, { colorSpace, generateMipmaps })
```

A PNG, JPEG or KTX2 on the device. Synchronous — it is uploaded by the time the call returns, so
`width` and `height` are readable immediately and there is no `onLoad`. The format is read from the
file's first bytes, not its extension.

Images are deduplicated by content and by colourspace: two paths holding the same picture, or a
`.png` and the identical image inside a `.glb`, are one upload, though each call still answers with
its own handle. Under `--assets` the path is inside the game directory and cannot climb out.

Put it on something with `new three.MeshLambertMaterial({ map })`. 16-bit PNGs are refused by name;
save as 8-bit. `read()` copies the pixels back off the device.

The option worth knowing about is `colorSpace`. It defaults to sRGB, which is right for a picture of
something and wrong for a map whose channels are numbers — a normal map, a roughness or metalness or
occlusion map, a height field. Those want `three.LinearSRGBColorSpace`, and getting it wrong has no
error and no obvious symptom: a normal map read as sRGB has its "no tilt" 0.5 decoded to 0.21, so
every surface leans the same way and the detail goes soft.

A full mip chain is built unless you say otherwise, so a textured floor stops shimmering at grazing
angles. An option this does not have is refused rather than ignored — there is no `magFilter` or
`wrapS` here.

### Properties

- `width`
- `height`
- `path`
- `alive`
- `colorSpace` — `'srgb'` or `'srgb-linear'`; fixed at upload, so load again to change it
- `levels` — how many mip levels it got
- `generateMipmaps` — whether it got a chain — the answer, not the request

### Methods

- `read(into)`
- `dispose()`
- `toJSON()`
- `toString()`

## MeshLambertMaterial

```js
new three.MeshLambertMaterial({ map, normalMap, metalnessRoughnessMap, aoMap, side, transparent, blending, opacity, roughness, metalness, reflectance })
```

The built-in shader with an image on it — the material to reach for when what you want is a picture
on a shape. It compiles nothing and cannot fail with a shader diagnostic.

Lambert is what it actually computes by default: the lights, an ambient floor, and no highlight until
`reflectance` or `metalness` asks for one. There is no environment.

It has no `color`, because `mesh.color` is the per-copy channel and multiplies into the sampled texel
— so one material tints a thousand copies differently and is still one draw call. With no map it is
the cheapest way to ask for a side, which is what a skydome needs.

**Four images, not one.** `map` is the base colour and the other three are the maps the built-in
shader reads beside it — a normal map, glTF's packed metallic-roughness pair, and an occlusion map.
None of them compiles anything either: they are sampler bindings on the pipeline that already
existed. The last three are *data* rather than pictures and have to be loaded
`{ colorSpace: three.LinearSRGBColorSpace }`; assigning an sRGB texture throws, because through an
sRGB view every value in them arrives bent and the result reads as a bad file.

### Properties

- `map` — a `three.texture`, or null; settable
- `normalMap` — a tangent-space normal map, or null; must be loaded linear
- `metalnessRoughnessMap` — glTF's packed pair: green is roughness, blue is metalness
- `aoMap` — an occlusion map, red channel; darkens the ambient floor and the environment only
- `roughnessMap` — Three.js has this and here it is half of `metalnessRoughnessMap`; assigning throws
- `metalnessMap` — the other half, and throws for the same reason
- `side` — `three.FrontSide`, `three.BackSide` or `three.DoubleSide`; settable
- `transparent` — derived from `blending`, and read-only — see Material
- `blending` — decided at construction and not settable — see Material
- `opacity` — 0 to 1; nothing unless built transparent — see Material
- `roughness` — 0 to 1, 1 by default — see Material
- `metalness` — 0 to 1, 0 by default — see Material
- `reflectance` — 0 to 1, 0 by default — see Material
- `repeat` — `[u, v]`, or one number for both; zero throws — see Material
- `offset` — `[u, v]`: where the map starts, in whole repeats
- `uvVariants` — up to eight `[offsetU, offsetV, turns, flip]` rows, one uv transform per copy, picked by `mesh.variant`; `null` clears it
- `stochastic` — sample this material's maps so a tiled surface stops having a period; for a texture with no structure in it
- `alive` — false once `dispose()` has been called on it

### Methods

- `dispose()`
- `toJSON()`

### Details

#### normalMap

A tangent-space normal map, or null. The frame is rebuilt per pixel from screen-space derivatives, so
it works on any mesh with uvs — a generated PlaneGeometry included — and no mesh here has or needs a
TANGENT attribute. A mirrored uv island comes out mirrored rather than flipped, which is the price of
that.

Load it linear:

```js
const bumps = three.texture('brick_n.png', { colorSpace: three.LinearSRGBColorSpace });
const wall = new three.MeshLambertMaterial({ map: brick, normalMap: bumps });
```

Through an sRGB view the stored 0.5 that means "no tilt" arrives as 0.21, so every surface leans the
same way and the detail goes soft. The setter refuses an sRGB texture rather than letting that
happen, and `ref.material.normalMap` from a glTF is already linear.

#### metalnessRoughnessMap

glTF's `metallicRoughnessTexture`: **green is roughness and blue is metalness**, one image rather
than two, which is what every exporter writes and what `ref.material` hands over.

It **multiplies** `roughness` and `metalness` rather than replacing them, which is what glTF says its
two factors mean — so a file's numbers and its map compose. The consequence is worth remembering:
this renderer's default metalness is 0, so a map on a material nobody set `metalness` on is
multiplied away. Set `metalness: 1`, which is glTF's own default, to let the blue channel speak.

Red is unused. Loaded linear, for `normalMap`'s reason.

#### aoMap

An ambient occlusion map, red channel.

**It darkens the ambient floor and the environment reflection, and not the lights.** An AO map
records how much of the sky a crevice can see and says nothing about a lamp — a lamp pointed into
that crevice still lights it. Applied to the direct light as well it reads as dirt painted where the
light is pointing, which looks plausible enough to ship and is wrong.

So on a scene with `three.light.ambient` at 0 and no `scene.environment`, this correctly changes
nothing.

#### roughnessMap

Three.js keeps roughness and metalness in separate images and this renderer does not: glTF packs them
into one, the loader hands one over, and the shader reads two channels of it. Assigning throws a
sentence saying so rather than doing nothing, because a property that silently has no effect is the
failure that gets blamed on the renderer.

#### metalnessMap

The other half of the same sentence — see `roughnessMap`.

## ShaderMaterial

```js
new three.ShaderMaterial({ fragment, vertex, uniforms, textures, bounds, side, transparent, blending, opacity, roughness, metalness, reflectance })
```

`fragment` is a Slang function `float3 shade(Surface s)` returning linear rgb.

`Surface` carries:

- `albedo`, `normal`, `uv`, `position`.
- `color` — this copy's own, already in albedo.
- `vertex_color` — the mesh's own COLOR_0 attribute, interpolated across the triangle, white where the
  file carried none, and not already in albedo. It is the one value here that varies across a
  surface, so it is a painted weight as often as a tint.
- `shadow` — how much of the sun reaches this point, 1 in the open and 0 under something; 1 everywhere
  with shadows off, and already folded into `lambert()`.
- `roughness`, `metalness`, `reflectance` — the material's own three, which `specular()` and
  `standard()` read.
- `height` — how far this point stands out of the surface the mesh has, where 0.5 is that surface.
  0.5 everywhere today: nothing writes relief into it yet, and a body with a height map of its own
  samples it directly.
- `variant` — its row of the table, clamped.
- `origin` — where this **copy** is: the instance's own world origin, one value for the whole copy.
  It is the seed a per-copy trick wants and the one thing a body cannot work out for itself —
  `position` varies per pixel, and there is no instance index here on purpose, because culling and
  re-bucketing renumber one between frames and a pattern keyed on that swims as the scene changes. A
  tint that drifts per copy, a macro noise that does not restart at every piece of a kit, a wave whose
  phase is the tree rather than the leaf. A merged mesh is one copy, so it is per merge and not per
  piece.

Each uniform is readable in the body by its own name; a uniform written as an array of arrays is a
table column, read as `name[s.variant]`.

`textures` is the same idea for images: `{ noise_map: tex }` declares a Sampler2D called `noise_map`
the body samples by that name, up to eight. You never write a binding number — the shader is generated
with the bindings in it and the host resolves each name through the compiled module's own reflection.
Sample with any uv you like, which is the point: `s.uv + float2(t, 0)` scrolls, `s.uv * 4` tiles,
`float2(k, 0.5)` reads a gradient as a lookup table. A sampler left null reads 1x1 opaque white.

Five helpers are already in scope in a body:

- `standard(s)` is the built-in shading, whole — `return standard(s);` draws exactly what a mesh with
  no ShaderMaterial draws. `standard(s, albedo, normal)` is the same with a colour and a normal you
  worked out yourself.
- `lambert(normal)` is the diffuse half alone, summed over every light with the shadow folded into the
  sun's term — so `return s.albedo * lambert(s.normal)` is a matte surface. `lambert(normal, ao)`
  takes an occlusion factor, which darkens the ambient floor and never the lights.
- `specular(s)` is the other half.
- `srgb_to_linear(c)` decodes a colour you wrote down yourself.
- `mapped_normal(s, texel)` applies a tangent-space normal map: hand it the map's rgb exactly as
  sampled and it answers with a world-space normal to give `lambert`.
- `stochastic_sample(image, uv)` samples one of your textures so that it stops repeating — the same
  thing `material.stochastic` does to the built-in maps, available here for a texture the body
  declared. Three taps, so use it on the map that tiles and not on all of them.

```slang
float3 n = mapped_normal(s, bumps.Sample(s.uv).rgb);
return s.albedo * lambert(n);
```

The meshes here carry no tangents, so that frame is rebuilt per pixel from screen-space derivatives:
it works on any textured mesh including a generated primitive, it is fragment-stage only, and it
cannot see the seam of a mirrored uv island. Load the map with
`{ colorSpace: three.LinearSRGBColorSpace }` — through the default sRGB the stored 0.5 that means "no
tilt" arrives as 0.21, every surface leans the same way and the bumps go soft.

It compiles on construction, so a bad shader throws here carrying the Slang diagnostic with the line
number you wrote. Needs a GPU device.

`shade()` returns rgb and never alpha: how much of the surface shows is the material's opacity times
this copy's `mesh.color` alpha, so a body cannot make geometry invisible by accident and a script can,
deliberately. `discard` works in a body and is how a dissolve or a cutout is done.

`vertex` is the other half: a Slang function `void displace(inout Vertex v)` that runs per vertex,
before anything is projected. `Vertex` is the varyings — write `v.position` (world space, after the
mesh's own transform) to move the vertex, and `v.normal`, `v.uv`, `v.color`, `v.vertex_color` and
`v.variant` to change what the fragment stage receives; `v.local` (object space), `v.index` (the
vertex number, a per-vertex seed) and `v.origin` (this copy's world origin, a per-copy one) are inputs
only.

Waves, flags, breathing, jitter, explosions, a mesh that inflates on a hit — all of them are one line
here and none costs a draw call, because the geometry never changes. The normal is not recomputed from
what you do to the position: write `v.normal` yourself if you moved the surface enough for the lighting
to care. A sampler reads with `SampleLevel(uv, 0)` in a vertex body, not `Sample` — there are no
derivatives to pick a mip with. Omitting `fragment` is allowed once `vertex` is given.

`bounds` is what a vertex body owes the renderer: how far, in world units, it can move a vertex.
Culling tests a mesh's own bounds, so a body that pushes geometry outside them draws something the
frustum was never told about — and the symptom is geometry vanishing at the edge of the screen and
coming back when the camera turns, which reads as a renderer bug. Too big costs a draw call that could
have been skipped; too small drops geometry you can see.

### Properties

- `uniforms` — live: `mat.uniforms.tint = [1, 0, 0]`, or `mat.uniforms.palette[2] = [1, 0, 0]`
- `textures` — live: `mat.textures.noise_map = otherTexture`, or null to put white back. Only the names
  given at construction exist; assigning any other throws
- `fragment`
- `vertex` — the displace body, or an empty string; read-only, like `fragment` — a new body is a new
  material
- `bounds` — how far the vertex body moves a vertex, world units; read-only, and what the frustum test
  is widened by
- `map` — a `three.texture`, or null; sampled as `Surface.albedo` before your `shade()` runs
- `side` — settable, and cheap after the first time each side is asked for
- `transparent` — derived from `blending`, and read-only — see Material
- `blending` — decided at construction and not settable — see Material
- `opacity` — 0 to 1; nothing unless built transparent — see Material
- `roughness` — 0 to 1, 1 by default — see Material
- `metalness` — 0 to 1, 0 by default — see Material
- `reflectance` — 0 to 1, 0 by default — see Material
- `repeat` — `[u, v]`, or one number for both; zero throws — see Material
- `offset` — `[u, v]`: where the map starts, in whole repeats
- `uvVariants` — one uv transform per copy, picked by `mesh.variant` — see Material
- `stochastic` — scatters this material's own `map`; a body's declared textures go through
  `stochastic_sample(image, uv)` instead — see Material
- `alive` — false once `dispose()` has been called on it

### Methods

- `dispose()`
- `toJSON()`

## LayeredMaterial

```js
new three.LayeredMaterial({ map, normal, mask, height, bump, layers, side, transparent, blending, opacity, roughness, metalness, reflectance })
```

An ordered stack of materials blended over a base one — terrain splatting, weathering, decals.

It is a ShaderMaterial whose `shade()` body is generated from the description, so everything a
ShaderMaterial has it has, and `mat.fragment` is the Slang that was written for you — read it when a
stack looks wrong.

The base material is `map` plus the mesh's own base colour, exactly as without this: the layers are
extra, and a stack with none of them shades as a MeshLambertMaterial.

`layers` is an array, outermost last — each is blended over everything under it as
`lerp(below, blend(below, layer), mask)`. A layer takes `map` (its albedo), `normal`, `emissive`,
`emissiveFactor`, `tint`, `opacity`, `roughness`, `metalness`, `metallicRoughness`, `height`, `bump`,
`blend`, `mask`, `maskSource`, `maskTexture`, `invert`, `uvScale`, `uvOffset`, `enabled`, `animated`
and `name`.

- `mask` is which channel this layer's weight is read from — `'r'`, `'g'`, `'b'` or `'a'` — which is
  the economy that makes a four-layer terrain one mask image instead of four. Pass that image as the
  top-level `mask`. A layer with no mask covers everything; `maskTexture` gives one layer a mask of its
  own; `invert` flips it.
- `maskSource` says which thing the channel belongs to: `'texture'` (the default) or `'vertexColor'`,
  which reads the mesh's own COLOR_0 attribute — a weight an artist painted per vertex, costing no
  sampler and no image at all.
- A layer that states no colour — no map, no tint, not animated — leaves what is under it alone rather
  than blending white over it, so `{ emissive: glow }` only glows and `{ normal: bumps }` only adds
  detail. Use a white map to paint white deliberately.
- `blend` is `'mix'` (the default), `'multiply'`, `'add'`, `'subtract'`, `'screen'`, `'overlay'`,
  `'softLight'`, `'difference'`, `'darken'` or `'lighten'` — Blender's Mix node modes, because that is
  where the glTF extension this implements comes from.
- `uvScale` is per layer and tiles the detail without tiling the mask, which is the whole trick of a
  splat map. It composes with `material.repeat` rather than replacing it.

Everything is baked into the shader as a literal unless you say `animated: true` on a layer, which
promotes its `tint` and `opacity` to a uniform you can write every frame —
`mat.layers[2].opacity = 0.25`. That costs 16 of the material's 104 uniform bytes, so at most six
layers may be animated; the rest cost the push block nothing.

The real ceiling is samplers: eight, counting one per layer `map`, `normal`, `emissive`, `height`,
`metallicRoughness` and own `mask`, plus one each for the shared mask and the base normal and height.
The base map does not count. `{ enabled: false }` drops a layer and its samplers entirely.

Load masks and normal maps with `{ colorSpace: three.LinearSRGBColorSpace }` — their channels are
numbers rather than colours, and through the default sRGB every weight comes out wrong.

A layer may change the surface, not just its colour: `roughness` and `metalness` are 0-to-1 numbers and
`metallicRoughness` is a map packed glTF's way (green rough, blue metal). They blend down the stack by
the same weight and the same blend mode the colour does, so a moss layer that multiplies its colour
also multiplies its roughness. State only what the layer means — a layer that says `roughness` says
nothing about `metalness`, and the material's own value carries through.

`height` is parallax: `bump: { strength, distance }` scales it, `distance` in metres, and the uv moves
under everything sampled after it. A height on the LayeredMaterial itself moves the whole stack — base
colour, base normal, the mask and every layer; a height on a layer moves that layer's own maps and
nothing else. 0.5 in the map is the plane the mesh already has. It is one step rather than a march, so
it shifts convincingly and does not occlude, and it does nothing in a bake.

A layer's `subsurface` is the one thing refused rather than ignored: it needs a light transport this
renderer does not have, and a material property that provably changes no pixel is worse than an error.

`asset.mesh(name).layers` hands you a description straight out of a glTF authored with
`CUSTOM_materials_layers`, so `new three.LayeredMaterial(ref.layers)` is the whole import.

### Properties

- `layers` — a view per enabled layer: `layers[i].map = tex` swaps an image, and `layers[i].tint` /
  `layers[i].opacity` read and write the ones declared animated
- `fragment` — the generated Slang — read-only, and the thing to look at first
- `uniforms, textures` — the ShaderMaterial proxies, under the generated names
- `map, side, transparent, blending, opacity, roughness, metalness, reflectance, repeat, offset,
  uvVariants, stochastic, alive` — as ShaderMaterial

### Methods

- `dispose()`
- `toJSON()`

## Group

```js
new three.Group(), or asset.instantiate()
```

Transforms its children and draws nothing itself, which makes it the way to keep several objects one
object: parent the pieces, place them relative to the Group once, and afterwards there is one
transform to move rather than a convention to remember.

`asset.instantiate()` answers with one of these carrying the file's own node hierarchy, and that one
is what `animations`, `play(name, {loop, speed, time, fade})` and `stop()` work on — a glTF clip
drives a whole subtree, so its root is where it is played. On a hand-built Group `animations` is empty
and `play()` throws saying which door to use.

There is no AnimationMixer: one clip at a time plus a crossfade. `fade` is seconds to blend out of
whatever is playing, and asking to fade into the clip already playing does nothing — which is what
makes `play(state.clip, { fade: 0.2 })` safe to call from a state machine every frame. Restarting a
clip outright is `play()` without a fade.

### Properties

- `position`
- `rotation`
- `scale`
- `visible`
- `name`
- `children`
- `parent`
- `static` — this will not move again — see the static-casters topic
- `collides` — per node and not inherited; set it on the meshes, not on the Group
- `animations` — clip names, from `asset.instantiate()`

### Methods

- `add(...)`
- `remove(...)`
- `traverse(fn)`
- `getObjectByName(name)`
- `getWorldPosition()`
- `boundingBox()`
- `boundsInParent()`
- `align(axis, edge, at)`
- `snapTo(other, side, axes)` — this piece on one side of that one, touching, or on a marker name
  both pieces carry
- `alignTo(other, axes)` — flush without touching
- `row(axis, pieces, opts)` — N pieces edge to edge along one axis
- `play(name, opts)`
- `stop()`
- `socket(bone)`
- `toJSON()`

## Box3

```js
new three.Box3(minX, minY, minZ, maxX, maxY, maxZ)
```

An axis-aligned box, and the answer to "how big is this actually". A kit piece's origin is wherever
whoever exported it left it, so nothing about a transform says where the piece's faces are — which is
what "put this window on that wall" is really asking.

`size` and `center` are derived from `min`/`max` rather than stored. `edge(axis, which)` is one face's
coordinate, and is what `align()` is written in terms of.

`containsPoint` is the trigger test that costs no host call — a box out of `object.boundingBox()`
against a position a script already has is the cheapest volume there is, and `three.physics` triggers
are what to use when the volume has to move. `intersectsBox` counts touching as overlapping, as
`three.query.box` does. `expandByScalar` answers with a new box, so it does not disturb the one it
grew from.

### Properties

- `min`
- `max`
- `size`
- `center`

### Methods

- `edge(axis, 'min' | 'center' | 'max')`
- `containsPoint(point)`
- `intersectsBox(other)`
- `expandByScalar(amount)`
- `union(other)`
- `clone()`
- `toJSON()`
- `toString()`

## MeshRef

```js
not constructible — asset.mesh(name) and asset.meshAt(i) answer with these
```

One piece of a loaded file: the handle `new three.Mesh()` wants, plus bounds.

Reading `bounds` costs no upload — the box comes out of the glTF JSON at load, so asking how big two
hundred kit pieces are before placing twelve of them still uploads twelve. It is not cached: a
reference that outlives its asset throws rather than answering with the size the mesh used to be.

### Properties

- `asset`
- `assetGeneration`
- `mesh`
- `name`
- `bounds` — a Box3 in the mesh's own space
- `layers` — this mesh's `CUSTOM_materials_layers` stack as a LayeredMaterial description, or null
- `material` — what this primitive's glTF material said, beyond the base colour, or null

### Methods

- `split()` — cut this mesh into its connected components, one geometry per piece
- `toJSON()`
- `toString()`

### Details

#### layers

`new three.LayeredMaterial(ref.layers)` is the whole import, and what you get first is a plain object
you may edit — drop a layer, retune an opacity, mark one animated.

Unlike everything else on a MeshRef this uploads the mesh, because a stack is texture slots and slots
exist only once the primitive is on the device. Every read hands back fresh Texture handles each
holding a reference, so read it once and keep what it gave you.

#### material

`{ alphaMode, alphaCutoff, doubleSided, normalMap, emissive, emissiveMap, emissiveIntensity, aoMap,
metalness, roughness, metalnessRoughnessMap }`, or null for a primitive that names no material. This
is what the loader used to drop.

Each map arrives with its colourspace already right — normal, occlusion and metallic-roughness are
data and load linear, emissive is a colour and loads sRGB — which is decided by the importer rather
than by you, and is the difference between a normal map that works and one that leans every surface
the same way.

It is a description and not a material: what to build from it is yours, and
`asset.instantiate({ materials: true })` is the shorter door.

`normalMap`, `aoMap` and `metalnessRoughnessMap` are three of `MeshLambertMaterial`'s own properties,
so a description goes straight onto a material that compiles nothing:
`new three.MeshLambertMaterial({ normalMap: d.normalMap, metalness: d.metalness })`. `metalness` and
`roughness` are the file's own numbers, and the map multiplies them — glTF defaults both to 1, so a
file that says nothing is fully metallic and is dark without a sky to reflect.

Like `layers`, this uploads the mesh and every read hands back fresh Texture handles holding
references, so read it once and keep it.

#### split

The answer to a kit that arrived as one merged mesh: a town square with 23 buildings in it, or a pack
of four animals, is one transform and one bounding box until it is cut, so nothing in it can be
placed, rotated, culled or picked on its own.

Two triangles are in the same piece when they share a vertex, which is the right cut for a merged kit
(they are merged by concatenation, so nothing welds them) and no cut at all for a surface that is
genuinely connected — a terrain with the houses extruded out of it comes back whole. Length one means
it was already one thing, and the one geometry you get is this mesh itself with nothing uploaded.

Each piece is an ordinary geometry: instanced, pickable, exportable, unloadable on its own, carrying
the source's colour and base colour map. It does not carry a layer stack, and a mesh that has one
throws instead of losing it quietly.

Expect the pack to include details that were modelled as separate shells — eyes, horns, hooves — so
filter by `piece.bounds.size` if you only want the bodies.

Not free and not automatic: it reads the geometry back and uploads one asset per piece, so it is a
load-time step. Splitting the same mesh twice answers with the same assets.

## Vector3

```js
new three.Vector3(null, x, y, z)
```

`position`/`rotation`/`scale` are live Vector3s: writing `x`, `y`, `z` or calling `set()` moves the
object.

Every method below except the read-only ones mutates and answers with `this`, which is Three.js's
convention and the one thing worth saying out loud: `a.cross(b)` does not mean "the cross product of a
and b", it means "a becomes the cross product". On a live vector that is a write to the object, so
`dir.copy(mesh.position).sub(target).normalize()` moves the mesh and
`mesh.position.clone().sub(target).normalize()` is what was meant.

The ones that only read are `dot`, `length`, `lengthSq`, `distanceTo`, `distanceToSquared`, `angleTo`,
`equals`, `clone` and `toArray`.

`normalize()` leaves a zero vector at zero rather than handing back three NaNs, because a direction is
almost always fed straight to something that aims, and a NaN aim renders as the object vanishing
rather than as an error.

In a loop compare `distanceToSquared` against `r * r`: `distanceTo` is a square root per pair to answer
a question that never needed one.

### Methods

- `set(x,y,z)`
- `copy(v)`
- `add(v)`
- `sub(v)`
- `multiplyScalar(s)`
- `divideScalar(s)`
- `addScaledVector(v,s)`
- `setScalar(s)`
- `negate()`
- `lerp(v,t)`
- `cross(v)`
- `normalize()`
- `dot(v)`
- `length()`
- `lengthSq()`
- `distanceTo(v)`
- `distanceToSquared(v)`
- `angleTo(v)`
- `equals(v)`
- `clone()`
- `toArray()`
- `toJSON()`
- `toString()`

## Random

```js
new three.Random(seed)
```

A seeded generator. It exists because `Math.random` throws away the determinism the rest of the engine
goes to some trouble to have: the fixed step, the solver's own accumulator and `state_hash` are all so
that the same inputs give the same frame, and one `Math.random()` in the gameplay layer costs all of it
— a bug that reproduces on the tester's machine and not on yours, with no way to bisect.

`three.randFloat`, `three.randInt` and `three.randFloatSpread` are Three.js's names drawing from a
shared stream that `three.seed(n)` resets. Construct one of these when two systems must not perturb
each other's sequence, because a level generator and a particle burst drawing from one stream means
adding a spark changes the terrain.

mulberry32 — fast, small, and not cryptographic. `seed(0)` is replaced, because a zero state is this
generator's one short cycle. `int(low, high)` is inclusive at both ends, as Three.js's `randInt` is.

### Methods

- `float()`
- `range(low,high)`
- `int(low,high)`
- `spread(range)`
- `chance(p)`
- `pick(list)`
- `sign()`
- `seed(value)`
- `toString()`

## Asset

```js
three.load(path)
```

A parsed `.glb` or `.gltf`. Three doors onto it: `instantiate()` for the file's own node hierarchy,
`node(name)` for one named part of that hierarchy, and `mesh(name)` for one piece you place yourself.

`instantiate()` is Three.js's `gltf.scene` — the file's nodes as Object3Ds, with the transforms the
file gave them. Use it for anything whose pieces are positioned by nodes rather than baked into the
vertices: a rig, a prop with parts, a level laid out in Blender. Instantiating twice gives two
independent trees over one upload. Its `name` argument names the tree it answers with and does not
pick anything out of the file — `node(name)` is the one that picks.

`node(name)` is a kit in one file: the node that name belongs to, and everything under it, as a tree
of its own. `asset.nodes` is the list of names it takes.

```js
const kit = three.load('buildings.glb');
const wall = kit.node('wall_stone');
wall.position.set(4, 0, -2);
scene.add(wall);
```

It is the door onto a piece of any shape, and the reason is worth knowing before a kit is authored.
`mesh(name)` matches a glTF *mesh*, and an exported mesh takes the name of the node that draws it only
when exactly one node does — a shape several pieces share keeps its geometry's name, `box`, because one
name cannot stand for all of them — while `instantiate()` builds the whole file however it is called. A
node keeps the name the file gave it whatever the piece is made of, so a piece that is four boxes is
reachable this way and no other: name the group, and name the meshes under it too if you want the
one-box pieces to answer to `mesh()` as well.

The subtree arrives carrying its own transform and none of its ancestors', so a piece authored at the
origin comes back at the origin whatever the file wrapped it in. Two nodes may share a name, and the
first one the file walks is the answer. Calling it twice gives two trees over one upload, as
`instantiate()` does, and the options mean the same things. Animation does too: the tree's root carries
the file's clips, and a channel naming a node outside the subtree drives nothing rather than failing.

`{ materials: true }` builds a material per glTF material and puts it on the meshes that wear it, which
is how a `.glb` authored with `alphaMode BLEND` renders blended and how a file's normal maps and
emissive maps reach the frame. Without it the file draws with its base colour and base colour map and
nothing else. It builds nothing for a material that is opaque, single-sided and has no normal or
emissive map, because that is the default material already. Occlusion and metallic-roughness are not
applied; `ref.material` has them and the reason. Off by default because it compiles a shader per
distinct material.

For a rigged file, the skeleton is left out by default and the character is posed from a table baked
once at load, so a hundred of them is a hundred nodes, one draw call and one uint per copy per frame —
give each a phase with `play(name, { time })`.

- `{ skeleton: true }` keeps the bones as objects and switches that copy onto a palette computed from
  them every frame, so writing `bone.rotation` moves the skin — a look-at, an aim, a foot on a slope.
  That is the hero-character option and it costs per copy.
- `{ skinning: 'compute' }` poses the vertices in a compute pass instead of in the vertex shader. It
  splits the character into its own draw call and holds a posed copy of the mesh, and only pays off
  when the same character is drawn more than once a frame.

`asset.imageAt(i)` is the file's own pictures as ordinary Textures, numbered the way the glTF numbers
them and counted by `asset.images`. It answers the same slot a placed mesh is drawing with, so what you
read is what is on screen, and it decodes on demand if nothing has placed a mesh yet. It takes the same
options `three.texture` does; sRGB is the default and is wrong for a normal or roughness map. Null comes
back for an image nothing here decodes.

`meshAsync` / `meshAtAsync` / `instantiateAsync` are the same three verbs with the upload awaited. A
`.glb` is parsed at load and its meshes reach the device one at a time when something first draws each,
so `scene.add` of a ninety-piece kit does ninety uploads inside one frame and that frame hitches.
Awaiting hands the engine a queue it drains one mesh per frame, so the kit arrives over ninety frames
with the game still drawing. Per mesh and not per file, because a level needs its floor before its
ninetieth crate. In a one-shot script with no animation loop there is no frame to protect and it costs
what the synchronous path costs. They reject if the asset is unloaded before their turn comes up.

### Properties

- `path`
- `meshes` — names, in load order
- `nodes` — the file's node names, each once, in the order the loader walks them — what `node(name)` takes. Read on demand rather than at load
- `animations` — clip names
- `images` — how many pictures the file holds
- `bones` — the rig's joint names — what `socket(name)` takes. Empty for a file with no skin

### Methods

- `mesh(name)`
- `meshAt(index)`
- `imageAt(index, { colorSpace, generateMipmaps })`
- `meshAsync(name)`
- `meshAtAsync(index)`
- `node(name, { skeleton, skinning, materials })`
- `nodeAsync(name, { skeleton, skinning, materials })`
- `instantiate(name?, { skeleton, skinning, materials })`
- `instantiateAsync(name?, { skeleton, skinning, materials })`
- `toJSON()`

## Level

```js
not constructible — three.level.load(path, parent, options) and three.level.create(kit) answer with these
```

A placement list, loaded: `kit`, the rows that describe it, the `Object3D` each one built, and the parent they hang from. `add(row, options)` places one row exactly as `load` does for each of the file's — validating the row's `id` is unique and its `snap.to`, if it has one, names a row already placed — and `refit()` replays every row that carries a `snap` against the objects as they stand now, leaving a freehand row exactly where it is. See `three.level` for the file this loads and saves.

### Properties

- `kit`
- `rows` — the file's rows, in file order, mutated in place by `toJSON()`
- `objects` — a Map from a row's `id` to the `Object3D` it built
- `parent` — where the rows are added; null until `three.level.load` sets it, or a script sets it directly after `three.level.create()`

### Methods

- `add(row, options)`
- `remove(id)` — throws if a later row's `snap.to` still points at it
- `refit()`
- `toJSON()` — what `three.level.save` writes

## Sockets

```js
character.socket(boneName)
```

Put the sword in the hand. `socket(name)` answers with an object parented to a bone of an instantiated
character — `add()` things to it and they ride the animation.

`asset.bones` is the list of names to pass, and it has to be: a rig calls its hand `mixamorig:RightHand`
or `hand.R` or `Bone.014` depending on who exported it, and the names are not guessable.

The two kinds of character answer differently, and that is the point. With `{ skeleton: true }` the
bones already are objects in the tree, so `socket()` hands back the bone itself. A baked character has
no bone objects at all — dropping them is what makes a hundred of them a hundred nodes — so it makes a
holder and the engine keeps it on the bone, reading the transform out of the same pose table the
character is drawn from. Either way what comes back is something you can `add()` to, place relative to,
and remove.

It costs a second copy of the file's pose table, once per asset and only from the first socket on it —
so a crowd nobody attaches anything to pays nothing. A socket on a character standing still costs
nothing per frame either; it is rewritten only when the pose changes.

Asking for a bone the rig has not throws, with the list of the ones it has.

### Methods

- `socket(boneName)`

## Geometry

```js
not constructible — use one of the shapes below
```

What every shape is: a handle three.c3 built, carrying the numbers you asked for. Hand it to
`new three.Mesh()`.

Constructing the same shape twice answers with the same asset, so a geometry per mesh costs nothing and
a thousand identical ones are one draw call; two different sizes are two.

There is no BufferGeometry and no attribute access — a script describes shapes, never vertices, and
ConvexGeometry's point cloud is a description too.

Sizes are world units and must be positive, segment counts are capped at 512, Y is up, and every shape
is centred on its own origin.

### Properties

- `type`
- `name`
- `parameters` — what you asked for, defaults filled in
- `asset`
- `mesh`
- `bounds` — a Box3 in the shape's own space — what it is, which is not always what it was asked for

### Methods

- `toJSON()`
- `toString()`

## BoxGeometry

```js
new three.BoxGeometry(width = 1, height = 1, depth = 1, widthSegments = 1, heightSegments = 1, depthSegments = 1, { uv } = {})
```

A box centred on the origin. The segment counts subdivide it and change nothing about its size.

`uv` is `'face'` (the default, Three.js's own layout) or `'local'`. Under `'face'` every face gets
the unit square, 0..1, whatever size the face is — right for a shape used at one size, wrong for a
kit: a roof built from a slope (a scaled box) and a hip (a hull) needs two different
`material.repeat` to wear one texture at the same texel density, and a wall panel's thin 0.2-deep
edge gets the same 0..1 span as its wide face and stretches. Under `'local'` a face's uv spans
0..its own length on each axis instead — a 3 x 1.6 wall face spans u 0..3 by v 0..1.6, and the
0.2-thick edge spans 0..0.2 on its thin axis — so `material.repeat` means texels per unit and one
material serves every piece of the kit, however it is cut. An unrecognised `uv` throws, naming
`'face'` and `'local'`.

### Properties

- `bounds`

### Methods

- `toJSON()`
- `toString()`

## SphereGeometry

```js
new three.SphereGeometry(radius = 1, widthSegments = 32, heightSegments = 16)
```

A UV sphere with its poles on the Y axis.

### Properties

- `bounds`

### Methods

- `toJSON()`
- `toString()`

## PlaneGeometry

```js
new three.PlaneGeometry(width = 1, height = 1, widthSegments = 1, heightSegments = 1, { uv } = {})
```

A one-sided rectangle in the XY plane, facing +Z — Three.js's orientation, which is vertical. A floor
is this with `rotation.x = -Math.PI / 2`. From behind it is invisible, because back faces are culled.

`uv` is `'face'` (the default) or `'local'`, the same option and the same tradeoff `BoxGeometry`
takes — see its entry above. A plane is one face, so `'local'` here means the whole rectangle's uv
spans 0..width by 0..height instead of the unit square, which is the same "texels per unit" reading
of `material.repeat` a box's faces get under `'local'`.

### Properties

- `bounds`

### Methods

- `toJSON()`
- `toString()`

## CylinderGeometry

```js
new three.CylinderGeometry(radiusTop = 1, radiusBottom = 1, height = 1, radialSegments = 32, heightSegments = 1, openEnded = false)
```

A cylinder or a truncated cone about the Y axis. Either radius may be 0, but not both.

### Properties

- `bounds`

### Methods

- `toJSON()`
- `toString()`

## ConeGeometry

```js
new three.ConeGeometry(radius = 1, height = 1, radialSegments = 32, heightSegments = 1, openEnded = false)
```

A cone about the Y axis with its point up. The same triangles as `CylinderGeometry(0, radius, height)`
— and the same asset, so the two spellings share a draw call.

### Properties

- `bounds`

### Methods

- `toJSON()`
- `toString()`

## TorusGeometry

```js
new three.TorusGeometry(radius = 1, tube = 0.4, radialSegments = 12, tubularSegments = 48)
```

A ring in the XY plane. `radius` is measured to the centre of the tube, so the shape is
`2 * (radius + tube)` across and `2 * tube` thick.

### Properties

- `bounds`

### Methods

- `toJSON()`
- `toString()`

## ConvexGeometry

```js
new three.ConvexGeometry(points, { uv } = {})
```

The convex hull of a cloud of points, and the way to make a shape that is not one of the six parametric
ones — a rock, a crystal, a gem, a chunk of debris, the bound of a scan.

`points` is an array of Vector3s, of `[x, y, z]` or of `{x, y, z}`, or a flat array or Float32Array of
coordinates; at least 4 points, at most 65536.

The hull is flat shaded, because its faces meet at hard creases. It carries uvs, but they are a
projection rather than an unwrap: every facet is mapped face-on at one uv unit per unit of local space,
so a texture is never stretched and is the same size everywhere on the hull and on anything beside it.
The only artefact is that two facets meeting at a crease do not line up along the shared edge, which
reads as nothing on the noise and grain a rock wants and as a break on a regular pattern.

That per-facet mapping is what `BoxGeometry`'s and `PlaneGeometry`'s `{ uv: 'local' }` also does —
a hull has always been local, there being no whole-shape unit square to fall back to. `uv` is accepted
here only as `'local'`, a no-op kept for symmetry with those two constructors; `'face'` is refused,
naming the reason, rather than quietly building a hull it cannot describe.

The points describe the shape, they are not its vertices — most are discarded and none can be read back.
`parameters.points` is the count you handed over. Two identical arrays are one asset; two runs of
`Math.random()` are two, because the key is bit-exact.

### Properties

- `bounds`

### Methods

- `toJSON()`
- `toString()`

## Path

```js
new three.Path(points)
```

A 2D outline built from straight segments and one curve — `moveTo`, `lineTo`, `closePath` and `absarc`,
chained, each returning `this`. `points` is an optional shortcut: an array of `[x, y]` pairs or
`{x, y}` objects, the whole outline handed over at once instead of built with `lineTo`.

`closePath()` is a no-op that returns `this` — the outline is always implicitly closed back to its first
point wherever it ends up, an `ExtrudeGeometry`'s outline or one of its holes — kept so a script ported
from Three.js does not have to drop the call. `moveTo` only makes sense as the first call on an empty
path; after that, use `lineTo`.

`absarc(x, y, radius, startAngle, endAngle, clockwise)` samples a circular arc into straight segments
immediately, at up to 12 segments per full turn scaled by how much of a turn the arc actually sweeps —
there is no deferred curve object here, `points` is the whole representation. There is no bezier,
quadratic or spline curve; see `ExtrudeGeometry`'s entry and `differences.md`.

### Properties

- `points` — the flattened outline so far, as `[x, y]` pairs

### Methods

- `moveTo(x, y)`
- `lineTo(x, y)`
- `closePath()`
- `absarc(x, y, radius, startAngle, endAngle, clockwise = false)`

## Shape

```js
new three.Shape(points)
```

A `Path` with holes cut out of it: `shape.holes` is a plain array a script pushes `Path`s onto, one per
hole. What `ExtrudeGeometry` sweeps — the outline is `shape`'s own points, from the `Path` it extends.

### Properties

- `points`
- `holes` — an array of `Path`, empty by default

### Methods

- `moveTo(x, y)`
- `lineTo(x, y)`
- `closePath()`
- `absarc(x, y, radius, startAngle, endAngle, clockwise = false)`

## ExtrudeGeometry

```js
new three.ExtrudeGeometry(shape, { depth, curveSegments, uv, bevelEnabled } = {})
```

A `Shape` swept along +Z into one closed mesh with no interior faces — the answer to "a shape cannot
have a hole in it", and the piece a kit is mostly made of: a wall with a window is this shape once,
instead of four boxes with coincident faces nothing will ever see.

Extrusion runs from z = 0 to z = `depth` (default 1, must be positive). A 3 x 1.6 wall with a 0.8 x 1
window cut at (1.1, 0.4), extruded 0.2 deep:

```js
const wall = new three.Shape();
wall.moveTo(0, 0).lineTo(3, 0).lineTo(3, 1.6).lineTo(0, 1.6).closePath();
const window = new three.Path();
window.moveTo(1.1, 0.4).lineTo(1.9, 0.4).lineTo(1.9, 1.4).lineTo(1.1, 1.4).closePath();
wall.holes.push(window);
const geometry = new three.ExtrudeGeometry(wall, { depth: 0.2 });
```

uvs are local by construction, not projected: a cap's uv is its own (x, y), and a side's is (distance
travelled along its ring since its own first point, z) — so `material.repeat` means texels per unit,
the same reading it has on a hull and on a `{ uv: 'local' }` box. `uv` takes only `'local'`; `'face'`
is refused, naming the reason, the same no-op `ConvexGeometry` accepts it as.

There is no bevel: `bevelEnabled` is refused rather than silently ignored, so a script ported from
Three.js finds out instead of getting a shape it did not expect — Three.js defaults `bevelEnabled` to
true, so a script that never mentions it gets the flat extrude it would have gotten from
`{ bevelEnabled: false }`. `curveSegments` (default 12) is accepted for the same signature Three.js
has, but does nothing here: the one curve this API has, `Path.absarc`, already flattened itself before
the shape reached this constructor.

Two shapes with the same outline points, the same hole points (in the same order) and the same depth
are one asset, the same rule every other shape here follows.

### Properties

- `bounds`

### Methods

- `toJSON()`
- `toString()`

## TerrainGeometry

```js
new three.TerrainGeometry({ width, depth, segments, heights, skirt })
```

Ground that is a surface rather than a pile of boxes, and the only geometry here that answers questions
afterwards.

`heights` is a `three.Field`, a flat array of `(segments + 1)` squared numbers row-major in z, or a
function `(x, z) => y` sampled at the grid points in world coordinates — the same frame everything else
in the scene uses, so one height function can drive the terrain, the mask and the scatter. Omit it for a
flat field to stamp into later.

It lies in the xz plane with +y up and is centred on the origin, its uv runs 0..1 across the whole field
so a splat mask lines up with no transform, and its normals come from the grid rather than from the
triangles — which is the difference between ground and steps. `skirt` is how far a wall drops around the
border so the map edge is not a hole.

One asset, one draw call: a 256-segment field is one `vkCmdDrawIndexed`.

`heightAt(x, z)` and `normalAt(x, z)` read the same grid the mesh was built from, through the same
interpolation, so what a script stands on cannot disagree with what is drawn. Off the map the edges
extend outwards rather than dropping to zero.

### Properties

- `bounds`

### Methods

- `heightAt(x, z)`
- `normalAt(x, z)`
- `toJSON()`
- `toString()`

## RibbonGeometry

```js
new three.RibbonGeometry({ path, width, y, terrain, lift, samples, columns })
```

A mesh that follows a curve — a road, a river, a path, a wall — and the answer to "why does the bend look
like it was drawn with a ruler".

`path` is sparse control points (`[[x, z], ...]` or `{x, z}`) and is bent by the same centripetal
Catmull-Rom as `three.catmullRom`, sampling `samples` cross-sections per control segment, so you write
the bends you can see and the ribbon is smooth between them.

Two modes, by the options:

- Flat at a constant `y` — a river or a pond, since a water surface is a plane and not a drape.
- Draped over `terrain` (a TerrainGeometry or a Field), where every vertex is `heightAt`/`valueAt` plus
  `lift` so the strip hugs the ground. `lift` keeps it from z-fighting where it lies.

`columns` is the cross-section: 2 is a straight chord across the width, more follows a crown or a bank.
`width` is the full width in world units; u runs across it and v along the length, so a texture flows
with the road.

One asset, one draw call — the strip is one mesh, not a row of re-edged boxes.

### Properties

- `bounds`

### Methods

- `toJSON()`
- `toString()`

## MergedGeometry

```js
not constructible — three.merge(root) or three.merge([mesh, ...]) answers with these
```

`three.merge`'s answer: every Mesh in a subtree, or an explicit array of them, concatenated into one
asset with each one's transform baked into its vertices — see `three.merge` in the functions
reference for the frame, the material and colour rules, and the round trip through `scene.export`
and `MeshRef.split()`.

### Properties

- `parameters` — `{ meshes, triangles }`: how many meshes went in, how many triangles came out
- `bounds`

### Methods

- `toJSON()`
- `toString()`

## Field

```js
new three.Field({ width, depth, segments, value })
```

A scalar grid in world coordinates — the authoring half of TerrainGeometry, and the same object a splat
mask is made of.

That is the point rather than a convenience: carve a river channel and stroke the mud mask from one
polyline, and the mud is where the water is by construction instead of because two functions were kept
in step.

Everything mutates in place and returns `this`, so it chains.

- `fill` and `add` take a number or an `(x, z) => v` in world coordinates.
- `flatten({x, z, width, depth}, y)` is a building pad, defaulting `y` to the mean under the rect —
  which is where the ground already was.
- `carve(path, width, depth)` lowers along a polyline and `stroke(path, width, value)` paints along the
  same one.
- `circle`, `blur`, `normalize` and `clamp` finish the set.

Every stamp takes a feather in world units with a smoothstep falloff.

`valueAt(x, z)` reads it back bilinearly before any upload, which is what lets a script place buildings
and scatter trees on ground that does not exist on the device yet.

`texture()` is the field as a mask in all four channels; `three.Field.mask({r, g, b, a})` packs up to
four of one resolution into the RGBA image a LayeredMaterial reads, always linear because a mask is a
weight and not a colour.

### Properties

- `width`
- `depth`
- `segments`
- `side`
- `values`

### Methods

- `fill(v)`
- `add(v)`
- `flatten(rect, y, feather)`
- `carve(path, width, depth, feather)`
- `stroke(path, width, value, feather)`
- `circle(x, z, radius, value, feather)`
- `blur(passes)`
- `normalize(low, high)`
- `clamp(low, high)`
- `range()`
- `valueAt(x, z)`
- `xAt(i)`
- `zAt(j)`
- `texture()`

## CatmullRomCurve3

```js
new three.CatmullRomCurve3(points, closed, curveType, tension)
```

The three-dimensional half of the curve pair, and the one a loop samples rather than a bake consumes: a
camera rail, a patrol route, a projectile arc, a rope. Three.js's class and method names.

`curveType` is `'centripetal'` (the default), `'chordal'` or `'uniform'` — centripetal passes through
every control point without swinging wide of a tight one, which is what a hand-written path always has.

**`getPoint(t)` and `getPointAt(u)` are not the same function**, and the gap between them is what makes
hand-written rail code look wrong: `t` is the curve's own parameter, spread evenly over the control
segments, so an object moving at a constant `t` per second speeds up through the widely spaced ones and
crawls through the close ones. `u` is spread evenly over the length, and that is the one anything moving
wants.

`three.catmullRom` is the other half of the pair: a ground path, `[x, z]` in and a dense polyline out,
for `field.carve`, `field.stroke` and RibbonGeometry.

### Properties

- `points`
- `closed`
- `curveType`
- `tension`

### Methods

- `getPoint(t)`
- `getPointAt(u)`
- `getTangent(t)`
- `getLength()`
- `getPoints(count)`
- `getSpacedPoints(count)`
- `toString()`

## QueryResult

```js
three.query.buffer(capacity)
```

A reusable answer for the flat form of `three.query.sphere` and `three.query.box`. Make it once, outside
the loop: the whole reason it exists is that a query answering with an Array of objects allocates, and a
hundred agents asking every frame is a hundred allocations a frame.

`handles` is the raw Int32Array of index/generation pairs the host filled, so a script that only wants to
count what is nearby never resolves anything at all; `objects()` resolves the lot in one walk of the scene
when it does.

`full` is true when the query filled the buffer, which means there may be more it could not tell you
about — a count equal to the capacity is otherwise indistinguishable from a scene that happened to have
exactly that many.

### Properties

- `handles`
- `capacity`
- `count`
- `full`

### Methods

- `objects()`
- `toString()`

## Entity

```js
class Critter extends three.Entity { ... }, then Critter.spawn(...)
```

An entity is a class, and this is the base to extend. There is no registration call beside the
declaration: the class registers itself on first use, reading `static capacity`, `columns`, `parent`,
`body`, `volume`, `trigger`, `collides` and `name` off itself.

`super()` first in the constructor, and it is not a formality — that is where a bare `new Critter()` is
refused, which is the one check a class with no columns cannot get any other way. An untracked instance
has no node in the scene, no body in the solver and no place in the live list, and the first sign of it
is a thing that never appears.

`Critter.step(name, fn)` and `Critter.frame(name, fn)` register a system under this class's name, so a
report says `Critter.walk` rather than `walk` — the same two verbs as `three.systems`, with
`system(name, fn, options)` leaving the phase open.

There is no `update()` to override, on purpose: continuous work is a named system in a readable order,
and a per-entity update method is the ninety-line animation callback again, once per class. `onSpawn()`
and `onRemove()` are the hooks there are.

### Properties

- `count`
- `free`
- `capacity`
- `trackName`
- `handles`
- `transform`

### Methods

- `spawn(...args)`
- `of(object)`
- `remove(instance)`
- `column(field)`
- `all()`
- `compact()`
- `clear()`
- `dispose()`
- `on(event, matcher, fn, options)`
- `off(name)`
- `step(name, fn, options)`
- `frame(name, fn, options)`
- `system(name, fn, options)`
- `pose(field, options)`
- `flush()`
- `sync()`

### Details

#### column

Columns are a window, not a copy. `static columns = { position: 3 }` with a `capacity` gives each
instance a subarray over one shared Float32Array, so `this.position[1]` and `Critter.column('position')`
are the same memory, and `three.steer` / `field.sample` / `three.moveAndSlideAll` are handed the storage
itself with nothing gathered.

Declare only the fields a bulk verb reads. `hp`, `stun` and `heading` are ordinary properties, because
nothing takes those in bulk. Measured, so it is a choice and not a rule: the copying alternative costs a
flat 115-148 ns per entity, which is 0.02 per cent of a frame at ten and 1.4 per cent at a thousand.
Declare columns in the low thousands and not before.

A column cannot grow, because every live window into it would dangle — which is why a capacity is
required beside them and why a full class throws rather than reallocating.

A columned field has a getter and no setter: `c.position[1] = 5` writes the column and
`c.position = [0, 5, 0]` throws, because swapping the window for a plain array would silently stop that
entity steering.

#### remove

A removal is immediate and the list compacts at the end of the frame.

`c.remove()` takes the body, the volume and the node away and makes `of()` answer null before it returns,
because a crate broken inside a spin has to stop colliding and stop drawing on this tick. Only the live
list waits, which is what makes `for (const c of Critter)` safe to remove from.

#### compact

An internal system named `<Class>.compact` closes the gaps last in the frame phase, moving the column
floats down and re-numbering the slots. A view is a function of the slot, so nothing has to be re-seated
— but a subarray held across a frame boundary points at whatever moved into that slot.

Compaction is stable rather than a swap-remove: a crowd that reorders itself whenever something dies
makes `three.steer`'s separation, which reads neighbours out of the same array, behave differently for
reasons nothing in the game can see.

#### of

Resolves up the parent chain, so a raycast hitting one mesh of an assembled eleven-part character answers
with the instance, and so does a volume.

#### pose

`pose(field, { lift, heading })` copies a 3-float column into the transform with a vertical offset — the
capsule centre and the model origin are never the same point — and `heading` may be a column or an
ordinary field.

#### flush

Sends the transform to the nodes in one crossing. `handles` is both the `self` column
`three.moveAndSlideAll` takes and the handle array this uses.

#### sync

Copies the transform back onto the objects, and carries the same trap `three.batch` does: a flush writes
the node, so the objects go stale and writing any single component of one afterwards undoes the flush for
that entity.

## Widget

```js
class Hud extends three.Widget { render() { ... } }, then Hud.mount()
```

A widget is a class and this is the base to extend — the interface written the way an immediate-mode one
is, costing what a retained one does.

`render()` describes the interface as it is now out of the node classes on `three.ui`; assigning a field
marks the widget for a re-render; and what reaches the host is the difference — one `three.ui.patch` per
changed value, and a `set` only when the shape itself changed.

So the two things `three.ui.set`/`patch` make a script carry stop existing: a unique string key per value
invented by hand, and the rule that every tree the game can set must still contain the keys the loop
patches.

The nodes are objects, one class per kind, on `three.ui`: Column, Row, Stack, Padding, Grid, Clip,
Anchored, Scroll, Panel, Rect, Label, Drawing, Button, Checkbox, Slider, Select, Tree, TextField.
Destructure them in one line — `const { Panel, Label, Button } = three.ui`.

Arguments are read by type, so the common spellings need no property names: a string is the text, a
function is the handler, a boolean is `checked`, a number is the value, an array is the options or the
rows, a plain object is the rest of the properties, and anything else is a child.

```js
new Button('Reset', () => reset());
new Checkbox('Wireframe', on, v => set(v));
```

Children are the arguments after the property bag rather than a `children` array, and a falsy one is
skipped, so `cond && new Row(...)` is a conditional row.

Panel is the one composite and it is the one that stops the arithmetic: a background behind a padded
column, sized to what is in it. A Stack fills, which is right for a scrim and wrong for a card, so a card
written by hand has to be told its height — measure a line, add up the rows, add the insets — and that
number stops being true the moment a row is added. `{ at: 'top-left', margin: 16 }` anchors it in the
frame, and `width` fixes the axis that should not hug.

Keys are paths. Every node is keyed by its position in its widget's tree, prefixed by the widget's own id,
so nothing is named by hand and two widgets cannot collide. Give a key by hand where a list reorders — the
same reason React wants one — and the text under somebody's fingers follows the row rather than the
position.

The invalidation is a Proxy: the constructor returns one, so every write to every field through every
reference anything captured marks the widget dirty. Its one blind spot is a field mutated rather than
assigned — `this.rows.push(x)` — and `update()` is the escape hatch for exactly that. A handler firing
marks it dirty too. The re-render runs once a frame in a system named `ui.widgets`; `three.ui.flush()` is
it now, for a screenshot taken without drawing a frame first.

Mounted widgets are floors of one interface, drawn in static layer order then mount order — a HUD and a
pause screen over it are two classes, and unmounting one leaves the other standing rather than rebuilding
it. An unmounted widget is a legitimate thing: `new Bar()` as a child of another's `render()` has its own
state and marks its owner dirty, which is how a row of stats is written once and used four times.

`three.ui.set` and `three.ui.draw` are refused while anything is mounted, because they are the other door
onto one interface and the class layer would overwrite them on the next frame. `three.ui.clear()` and
`three.Widget.unmountAll()` are how the class layer goes away. `onMount()` and `onUnmount()` are the hooks
there are.

### Properties

- `isMounted`
- `count`
- `layer`

### Methods

- `mount()`
- `unmount()`
- `update()`
- `render()`
- `mount(...args)`
- `all()`
- `unmountAll()`

## Cooldown

```js
three.cooldown(duration, options)
```

A scalar gameplay timer — the player's spin, a hurt window, coyote time — for the `if (x > 0) x -= dt`
pattern written out by hand at every one of those call sites.

Ticked, not read off `three.clock`: `three.clock.time` only advances once per host tick, before the fixed
loop decides how many steps it owes that tick, so a window shorter than one fixed step would see zero
elapsed time across a multi-step catch-up frame. A Cooldown instead sits in a module-level list a
lazily-registered `three.systems` entry decrements every step — which is also why a paused `three.clock`
freezes it for free.

`duration` is seconds greater than zero. Options are `{ recover, phase }`: `recover` is seconds after
`active` ends before `ready` is true again (0 by default), and `phase` is `'fixed'` (the default) or
`'frame'`.

`start(options)` starts it if ready and answers whether it did. `{ restart: true }` starts it even
mid-active or mid-recovering — coyote time re-armed every grounded frame, or a buff refreshed by a second
pickup — and a refused start changes nothing. `cancel()` ends it now and skips recovery: "the spin was
interrupted", not "the spin finished early".

`duration` and `recover` are ordinary writable properties and every getter reads them fresh, so upgrading
the spin needs no re-`start()`. `dispose()` takes it out of its phase's tick list, and takes the phase's
system back out of `three.systems` the moment nothing else needs it.

### Properties

- `duration`
- `recover`
- `started`
- `active`
- `ready`
- `recovering`
- `remaining`
- `progress`
- `elapsed`

### Methods

- `start(options)`
- `cancel()`
- `dispose()`
- `toString()`

## TransformBatch

```js
three.batch(objects, { trs })  |  three.batch(objects, { euler: true })
```

A Float32Array-shaped bulk write over many nodes.

`positions` is three floats per object, seeded from where they are now, so a batch made and immediately
flushed changes nothing. `flush()` sends the lot in one crossing and answers with how many landed; a
member that has left the scene is skipped rather than throwing, because a crowd where one agent was
removed this frame is ordinary.

Two rotation forms, and they are not redundant:

- `{ trs: true }` is a stride of ten — position, an xyzw quaternion, then scale — for a batch written by
  arithmetic, where whatever produced the rotation (a look-at, a slerp, a physics read-back) produced a
  quaternion, and converting it to Euler to send it would be lossy at every gimbal-locked pose.
- `{ euler: true }` is a stride of nine — position, an xyz Euler triple, then scale — for a batch written
  by a game, where the rotation is a heading and a limb swing: one angle each, typed by a person. This is
  what makes a crowd of characters one crossing instead of four: a critter writing a group position, a
  group heading and two leg angles measured 1.48 µs a frame as four ordinary writes and 405 ns through one
  batch.

They also seed differently, for the same reason. A TRS batch starts at an identity rotation and a unit
scale, because reading the objects' Euler angles and converting them would silently rewrite rotations the
script set by hand; an Euler batch is the script's own numbers and is seeded from `object.rotation` and
`object.scale`. `rotationAt(i)` and `scaleAt(i)` give the index those start at, so `i * stride + 3` is
never written out by hand.

Flush writes the node, and the object stops agreeing with it. `object.position` and `object.rotation` are
JavaScript numbers the host is never the authority on, and a batch goes straight to the node — so reading
`object.position.x` back gives the stale value, and worse, writing any single component afterwards undoes
the batch, because `object.position.y = 5` sends all nine of the object's numbers and overwrites the
rotation and scale the batch wrote. It renders as a crowd snapping back to a pose it had frames ago.

`sync()` is the fix and it is opt-in: it copies the array back onto the objects in JavaScript with no
crossing. Call it when a script is about to touch those objects by hand again, and not every frame merely
because it is there. `boundingBox()`, `align()` and the follow camera all read the host and are unaffected.

It is not a faster way to move a dozen things — five hundred ordinary `mesh.position.set` calls are
0.245 ms, three per cent of a frame. What it is for is the case where the write is already a loop over
numbers: a crowd steered by `three.steer`, a particle field, a chunked terrain.

### Properties

- `positions`
- `data`
- `handles`
- `objects`
- `trs`
- `euler`
- `mode`
- `stride`
- `length`

### Methods

- `flush()`
- `sync()`
- `rotationAt(i)`
- `scaleAt(i)`

## NavField

```js
three.nav.field(goals)
```

A solved flow field over the current `three.nav.bake()` — the solve kept, which is the whole reason there
are two navigation verbs instead of one. `three.nav.path` solves the entire reachable set and throws it
away after one answer, so a hundred agents heading for the same door is a hundred solves for one field.

`direction(point)` is a unit XZ vector, or zero for nowhere to go — standing on the goal, off the mesh, or
in a pocket no goal reaches — and `cost(point)` is how those are told apart. Cost is measured along the
ground rather than through walls, and is Infinity for unreachable.

Feed the field to `three.steer` rather than calling `direction()` in a loop: that is one crossing for the
whole crowd instead of one per agent.

Freed by `dispose()` and by disposing the scene it belongs to, and nothing else — a field is one float per
walkable cell and this API does not collect.

### Properties

- `alive`

### Methods

- `direction(point)`
- `cost(point)`
- `reaches(point)`
- `sample(positions, { costs, directions })`
- `dispose()`
- `toString()`

### Details

#### sample

Direction and cost for a whole crowd in one crossing, and the reason `direction` and `cost` are the wrong
verbs to call in a loop — not because of the crossing but because of the argument checking in front of it.
The bare host call that answers a number measures 143 ns; `cost(point)`, the same call through the
`readVector` that allocates a three-element array and runs three `Number.isFinite` checks to be polite
about its argument, measures 652 ns; `sample` measures 159 ns an agent.

`positions` is three floats per agent and is read. `costs` is one float per agent and `directions` is
three, and either may be left out, so a caller asking only how far everyone is pays for no directions.

A negative cost is unreachable here, where `cost(point)` answers Infinity. The two disagree on purpose:
converting would mean a JavaScript pass over the array, which is precisely the loop this exists to avoid,
and C3 has no infinity constant to write into a Float32Array instead. `costs[i] < 0` is the test;
`Number.isFinite` is not.

## Box3Helper

```js
new three.Box3Helper(box, color = 0xffff00)
```

A wire box drawn exactly where a `three.Box3` says — the helper to reach for when the box came from
somewhere that is not one object: a plot to fill, a gap to check, the union of two things.

`box` is settable and the helper follows it. It is read in the frame of whatever the helper is added to,
so a box from `boundsInParent()` belongs under the same parent and a box from `boundingBox()` belongs
under the scene.

Draws over everything: the line pipeline tests no depth, because the times you ask where something is are
the times it is inside a wall.

### Properties

- `box` — settable — the helper moves and rescales to it
- `position`
- `rotation`
- `scale`
- `visible`
- `name`
- `geometry`
- `children`
- `parent`
- `color` — per copy, free: `[r,g,b]` or `0xff8800`
- `material` — always null, and assigning throws — a helper draws with the line material
- `variant` — meaningless here: the line material has no table
- `static` — meaningless here: a helper casts no shadow to cache
- `animations` — always empty
- `collides` — already false in effect: a helper is in no query
- `morphs, weights` — inherited from Mesh; a helper's geometry has no morph targets

### Methods

- `add(...)`
- `remove(...)`
- `traverse(fn)`
- `getObjectByName(name)`
- `getWorldPosition()`
- `boundingBox()`
- `boundsInParent()`
- `align(axis, edge, at)`
- `snapTo(other, side, axes)` — this piece on one side of that one, touching, or on a marker name
  both pieces carry
- `alignTo(other, axes)` — flush without touching
- `row(axis, pieces, opts)` — N pieces edge to edge along one axis
- `play(name, opts)`
- `stop()`
- `socket(bone)`
- `toJSON()`

## BoxHelper

```js
new three.BoxHelper(object, color = 0xffff00)
```

The box of an object and everything under it — "how big is that actually, and where does it end".

It must hang from the same parent as the object it measures, and is refused anywhere else: the box is
measured in that frame, so a helper parented elsewhere would be drawn wherever the two frames differ,
which is a box in the wrong place rather than no box.

The usual spelling is therefore the Three.js one — `scene.add(piece); scene.add(new three.BoxHelper(piece))`
— and a nested piece takes `piece.parent.add(...)`. Nothing watches the object, so call `update()` after
moving it.

### Properties

- `object` — what it measures, read-only
- `box` — the box it is currently drawn on
- `position`
- `rotation`
- `scale`
- `visible`
- `name`
- `geometry`
- `children`
- `parent`
- `color` — per copy, free
- `material` — always null, and assigning throws
- `variant` — meaningless here
- `static` — meaningless here: a helper casts no shadow to cache
- `animations` — always empty
- `collides` — already false in effect: a helper is in no query
- `morphs, weights` — inherited from Mesh; a helper's geometry has no morph targets

### Methods

- `update()`
- `add(...)`
- `remove(...)`
- `traverse(fn)`
- `getObjectByName(name)`
- `getWorldPosition()`
- `boundingBox()`
- `boundsInParent()`
- `align(axis, edge, at)`
- `snapTo(other, side, axes)` — this piece on one side of that one, touching, or on a marker name
  both pieces carry
- `alignTo(other, axes)` — flush without touching
- `row(axis, pieces, opts)` — N pieces edge to edge along one axis
- `play(name, opts)`
- `stop()`
- `socket(bone)`
- `toJSON()`

## AxesHelper

```js
new three.AxesHelper(size = 1)
```

Red +X, green +Y, blue +Z from the origin — where a pivot is and which way it faces, which is the question
a kit piece whose origin is in an unexpected corner makes somebody ask. Parent it to an object to see that
object's pivot.

It is a Group of three meshes over one segment asset, so a hundred of them are still one draw call.

Remember that a helper parented to a piece is inside that piece's box: align first, add the axes after.

### Properties

- `size` — settable — rescales the three arms, builds nothing
- `position`
- `rotation`
- `scale`
- `visible`
- `name`
- `children`
- `parent`
- `static` — meaningless here: a helper casts no shadow to cache
- `animations` — always empty
- `collides` — already false in effect: a helper is in no query

### Methods

- `add(...)`
- `remove(...)`
- `traverse(fn)`
- `getObjectByName(name)`
- `getWorldPosition()`
- `boundingBox()`
- `boundsInParent()`
- `align(axis, edge, at)`
- `snapTo(other, side, axes)` — this piece on one side of that one, touching, or on a marker name
  both pieces carry
- `alignTo(other, axes)` — flush without touching
- `row(axis, pieces, opts)` — N pieces edge to edge along one axis
- `play(name, opts)`
- `stop()`
- `socket(bone)`
- `toJSON()`

## GridHelper

```js
new three.GridHelper(size = 10, divisions = 10, color = 0x888888)
```

A ruled square in the XZ plane, centred on the origin: where the ground is and how big a metre looks.

One colour, not Three.js's two — the darker centre line would be a second mesh here for a distinction
nothing has needed.

Keyed on the divisions alone, so `GridHelper(100, 10)` and `GridHelper(40, 10)` are one asset at two scales
and one draw call. There is no `size` to read back because the size is the scale: `grid.scale.x`, and it is
live. Divisions are capped at 256.

### Properties

- `divisions` — read-only — a different count is a different mesh
- `position`
- `rotation`
- `scale`
- `visible`
- `name`
- `geometry`
- `children`
- `parent`
- `color` — per copy, free
- `material` — always null, and assigning throws
- `variant` — meaningless here
- `static` — meaningless here: a helper casts no shadow to cache
- `animations` — always empty
- `collides` — already false in effect: a helper is in no query
- `morphs, weights` — inherited from Mesh; a helper's geometry has no morph targets

### Methods

- `add(...)`
- `remove(...)`
- `traverse(fn)`
- `getObjectByName(name)`
- `getWorldPosition()`
- `boundingBox()`
- `boundsInParent()`
- `align(axis, edge, at)`
- `snapTo(other, side, axes)` — this piece on one side of that one, touching, or on a marker name
  both pieces carry
- `alignTo(other, axes)` — flush without touching
- `row(axis, pieces, opts)` — N pieces edge to edge along one axis
- `play(name, opts)`
- `stop()`
- `socket(bone)`
- `toJSON()`

## WireframeHelper

```js
new three.WireframeHelper(meshOrGeometry, color = 0xffffff)
```

A mesh's own triangles as the edges between them — the tool for two faces 0.01 apart z-fighting into a
starburst, which is invisible in a solid render and obvious the moment the edges are drawn.

Takes a Mesh that is already in the scene, or the geometry / `asset.mesh(name)` it draws.

The mesh has to be on the device. A generated shape is uploaded when it is constructed and works straight
away, but a mesh out of a file reaches the device when something drawing it is added to a scene, and until
then there are no triangles to read — you get a sentence saying so, not an empty helper.

Add it as a child of the mesh — `piece.add(new three.WireframeHelper(piece))` — because the edges are in
the mesh's own space and a child at the identity transform overlays it to the pixel.

Each shared edge is drawn once. A Group has no triangles of its own: traverse it and make one per Mesh.

### Properties

- `of` — the name of the mesh these edges belong to
- `position`
- `rotation`
- `scale`
- `visible`
- `name`
- `geometry`
- `children`
- `parent`
- `color` — per copy, free
- `material` — always null, and assigning throws
- `variant` — meaningless here
- `static` — meaningless here: a helper casts no shadow to cache
- `animations` — always empty
- `collides` — already false in effect: a helper is in no query
- `morphs, weights` — inherited from Mesh; a helper's geometry has no morph targets

### Methods

- `add(...)`
- `remove(...)`
- `traverse(fn)`
- `getObjectByName(name)`
- `getWorldPosition()`
- `boundingBox()`
- `boundsInParent()`
- `align(axis, edge, at)`
- `snapTo(other, side, axes)` — this piece on one side of that one, touching, or on a marker name
  both pieces carry
- `alignTo(other, axes)` — flush without touching
- `row(axis, pieces, opts)` — N pieces edge to edge along one axis
- `play(name, opts)`
- `stop()`
- `socket(bone)`
- `toJSON()`
