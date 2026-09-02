# Functions

# Scenes, loading and the window

## three.load(path)

Read a `.glb` or `.gltf`. Nothing is uploaded: this parses the JSON and answers with an Asset that
knows its meshes, their bounds and the file's node tree. A mesh reaches the GPU when a Mesh drawing
it is added to a scene, so loading a 200-piece kit to place twelve costs twelve.

Under `--assets` the path is relative to the assets directory and cannot climb out of it, so
`three.inventory()` paths go straight in; otherwise it is relative to where three was started.

Loading the same path twice returns the same asset — unless it was unloaded in between, which gives
a fresh one and makes the old handle throw. Use `asset.instantiate()` for the file's own hierarchy
and `asset.mesh(name)` for one piece of it.

## three.merge(root)

`MeshRef.split()` in reverse: every Mesh in a subtree, concatenated into one asset with each one's
transform baked into its vertices. Ten buildings out of a kit are 2,463 nodes because every piece is
a hierarchy of boxes rather than a mesh — merging turns a piece that draws correctly as forty nodes
into the same picture as one.

Two spellings:

```js
three.merge(root)          // every Mesh under root, in root's own frame
three.merge([a, b, ...])   // exactly these meshes, in their shared parent's frame
```

A mesh's transform relative to the frame is the product of the local matrices from the mesh up to,
but excluding, `root` (or the array form's shared parent) — a mesh whose parent is null carries no
ancestor transform to exclude, so it merges in world. That is what makes
`new three.Mesh(three.merge(piece), material)` placed where `piece` was draw the same picture `piece`
did, as one instance instead of however many meshes `piece` was:

```js
const kit = three.load('kit/buildings.glb');
const piece = kit.node('wall_stone');
const material = new three.MeshLambertMaterial();
const wall = new three.Mesh(three.merge(piece), material);
wall.position.copy(piece.position);
scene.add(wall);
```

Skipped, silently: a helper (anything drawing with the line material — `Box3Helper`, `BoxHelper`,
`AxesHelper`, `GridHelper`, `WireframeHelper`) has index pairs rather than triangles, and an
invisible node draws nothing to bake, so `visible = false` prunes the whole subtree under it the
same way rendering does. A subtree with nothing left after that throws — "nothing to merge" — rather
than answering with an asset that draws nothing.

Refused: every mesh must share one material by identity (`mesh.material === mesh.material`, with the
shared default `null` counting as one) and one `variant`. A material is a pipeline and a variant a
row of its table, both chosen once per draw call, and a merge is one draw call — two materials cannot
become one asset, so this throws naming the first two that disagree rather than keeping one and
silently dropping the paint job on the meshes that named the other. `mesh.color` has nowhere else to
disagree from and is not refused: the built-in shading already multiplies a vertex colour attribute
into albedo beside the per-instance one, so each input's `color` bakes into the merged mesh's own
vertex colours instead — a wall merged with a differently tinted door keeps the door's tint.

Interior faces are still there. A wall merged with the window frame sitting inside it is one mesh
with the coincident inside-the-wall faces intact, because a merge is concatenation and nothing
cleverer. `ExtrudeGeometry` is the tool that removes a hole's interior faces by construction, and
stays the answer for a shape that should never have had them; this is the tool for turning a hundred
nodes that already draw correctly into one.

The result is one asset and one draw call per copy, like every other geometry — merging trades
instancing for node count, not the other way round. A piece used a hundred times across a level is a
hundred instances and one draw call whether or not it is merged, because it was already one asset;
what merging removes is the *node*, forty transforms and forty scene-graph entries for forty boxes
that make up one wall, down to one of each. Two different pieces merged into one asset are one asset,
not two — reuse across a level is a question about node count, and merging answers it, never about
which pieces happen to look alike.

`scene.export` writes a merged mesh exactly — real normals and real uvs, not a hull's averaged and
projected ones — and `MeshRef.split()` on it gives the pieces back, cut the same way any merged kit
is: two triangles are in the same piece when they share a vertex, which a merge's own concatenation
never does across two different inputs.

## three.render(scene, camera)

Draw one frame. `camera` is optional and must be `three.camera`.

## three.stats()

The numbers in the stats section, for the whole scene, with culling off.

The six `...Ms` are the exception: they measure the last frame drawn rather than the scene, so they
move when nothing about the scene has. `gpuMs` is the frame and the other five are what it was spent
on — which is how you find out that a slow scene is slow in the shadow pass.

The four `...Bytes` that are not `textureBytes` or `poseBytes` — `geometryBytes`, `targetBytes`,
`postBytes`, `shadowBytes` — are memory the renderer owns rather than the scene, so they read the
same whichever scene you ask, and between them they are most of what a three process holds.

## three.scenes

Every scene that exists, as `[{ id, active, held, nodes }]`. `stats().scenes` is the count; this is
what the count is made of.

`new three.Scene()` shows a new world without freeing the one before it, so a script that builds a
scene per `run_script` holds every one of them — a node pool, a physics world and a set of asset
references apiece, drawn by nothing.

`held` says what `three.sceneById(id)` will give you back. True is the same Scene object with its
children intact, and it stays true across `run_script`s. False means no Scene was ever made for it
here — the scene the process starts with reads that way — and `sceneById` mints a handle instead.

`three.disposeInactive()` frees them all without naming any.

## three.sceneById(id)

The Scene for a host id — the one a script built, or a handle onto one nothing here wrapped.

`three.sceneById(s.id) === s` for any scene this runtime built, including one built two `run_script`s
ago, so identity survives the end of the call that made it.

For the other kind — the scene the process starts with — everything that goes through the host works:
activate, dispose, stats, export, background, raycast, pick. But `children` is empty, because those
nodes are the host's and no object was ever made for them. It is a handle, not the tree, and looking
one up flips its `held` to true. `scene.id` is the other direction.

## three.disposeInactive()

Free every scene except the one being rendered, then sweep. The level transition is: activate the
next one, dispose the rest, `three.unloadUnused()` — and this is the last two.

It cannot leave the frame with nothing to draw, because the host refuses to dispose the scene being
rendered, so activate what you are keeping first.

Answers with `{ scenes, assets, meshes, textures, bytes }`. The second half is often zero and that is
right: two scenes over one kit means disposing either frees nothing, and `bytes` counts texture bytes
alone. `stats().geometryBytes` before and after is the other half.

## three.unloadUnused()

Free every asset no live mesh names, every mesh of a still-used file that nothing draws, and every
texture that goes with them.

Answers with `{ assets, meshes, textures, bytes }`. `meshes` counts pieces given back without their
file, which is what lets a level swap which parts of a kit it places without reloading the kit.
`bytes` is texture bytes — the images that went, not the geometry — so a sweep that freed a hundred
megabytes of vertex streams and no images answers 0; `stats().geometryBytes` is the other half.

`scene.unload()` is this plus emptying the scene, and is what a level transition wants. An asset
loaded but never added has no references either, so it goes too — load the next level after
unloading, not before.

## three.quit()

Close the window and end the process — what an in-game menu's Quit calls, and the only way a game
closes itself.

It returns and the process is still up: the host closes between this frame and the next, because
closing inside the click handler that asked would free the engine that handler is running in. So the
frame already built is the last one shown and a fade-out ending on this call gets to finish — but
nothing after the call is prevented from running either. Treat it as a request, not a return.

No argument and no exit code: a game that closed on purpose succeeded. Escape does the same in the
window, but only under `--debug`, so this one works in every run and escape is not something to ship
a menu on top of. A run with no host loop (a `--frames` batch) takes the request and never acts on it.

## three.reload()

Boot this game again from its own source — the same thing shift+R does in the window under `--debug`.

A new JavaScript context: the animation loop, every handler, every live object and every module the
script imported are gone, and `main.js` runs again from the top.

What survives is the machine rather than the world — loaded assets (`three.load` answers out of
memory, no file is reopened), compiled pipelines (a material rebuilt from the same shader source is a
cache hit, no Slang runs), the camera, and `three.persist`. Physics bodies and the nav bake go with
their scene, which is freed. Materials and textures the old script held handles to are given back —
nothing else would ever dispose them — so `stats().materials` and the images a `three.texture()` made
drop to zero, while an image a resident asset owns stays with it.

It returns immediately and the reload has not happened yet: the host performs it between this frame
and the next. Over `--mcp` that is the point — edit a `.js`, call this, and the next screenshot is of
the edited file. A run with no host loop takes the request and never acts on it.

## three.persist

The one object that survives `three.reload()`, and the whole of what does. Written by the game and
read by the game, carried across as JSON, so what may go in it is what `JSON.stringify` accepts.

Put numbers in it, not handles — a Mesh, a Scene or a body is an index into a pool that is about to
be freed. A value it cannot serialise (a cycle, a Map, a function) is reported on the terminal and
dropped rather than half-kept. Empty on a first boot.

The shape is `if (three.reloaded) player.position.set(...three.persist.at);` plus an animation loop
that keeps `three.persist.at` up to date.

## three.reloaded

False on the first boot of a process and true on every boot after a `three.reload()` or a shift+R
under `--debug`. The only way a script can tell the two apart, and what decides whether
`three.persist` means anything.

## three.inventory()

Every `.glb` and `.gltf` under the assets directory, described without loading any of it:
`[{ path, triangles, nodes, skins, meshes: [{ name, triangles }], animations: [name],
markers: [{ name, piece, position }], bounds: { min, max } }]`.

Read out of the JSON chunk, so it is cheap on a kit of any size — ask this before `three.load` to
find out what is worth loading. `path` is what `three.load` wants. Empty when three was not started
with `--assets`.

A marker is a leaf node with no mesh — the empty a kit author drops where two pieces are meant to
meet, the same way a Blender kit ships a connection point. `piece` is the top-level node the marker
sits under (empty when the marker is itself top-level) and `position` is in that piece's own frame —
the same one `asset.node(piece)` hands back — so an agent can read where a kit's pieces are meant to
join before it loads anything.

## three.readText(path)

A text file out of the assets directory, as a string — and `three.readJSON(path)` is the same file
parsed. The third thing that lives there beside the `.glb` and the `.png`: the level list that places
a kit, a table of stats, a dialogue script. A file a person edits in the repo, beside the kit it
names, that ships with the game.

```js
const kit = three.load('kit/buildings.glb');
for (const [piece, x, y, z, turns] of three.readJSON('levels/lumbridge.json') ?? []) {
  const m = kit.mesh(piece);
  m.position.set(x, y, z);
  m.rotation.y = turns * Math.PI / 2;
  scene.add(m);
}
```

This is `three.load`'s door with nothing loaded through it, so the sandbox is the same one: a path
that climbs out of the assets directory throws, a leading `/` means that directory rather than the
disk's root, and the paths `three.inventory()` hands back go straight in. Without `--assets` the path
is used as written, exactly as `three.load`'s is.

`three.writeText(path, text)` is this door the other way — see below.

A file that is not there answers null rather than throwing — `three.save.readText`'s answer and not
`three.load`'s — because "no level here yet" is a question an editor asks rather than a failure. A
file over 4 MB throws, and so does one whose bytes are not UTF-8: this reads text, and a `.glb`
opened by mistake says which verb it wanted.

Containment is by name and not by `realpath`, as it is for `three.load` and for `import`: a symlink
inside the assets directory pointing out of it is followed. The boundary is against a script reaching
out, which is the one that gets written by accident.

## three.writeText(path, text)

A text file into the assets directory, and `three.writeJSON(path, value)` is the same file
stringified — `JSON.stringify(value, null, '\t')`, so a level list saved this way is a diff worth
reading. `three.readText`'s door the other way: the level list a script builds has to land somewhere
that ships with the game, and until this existed the only somewhere was
`<application data>/three.c3/<slug>`, which is not where the kit is and not what a person commits.

```js
three.writeJSON('levels/lumbridge.json', rows);
const rows2 = three.readJSON('levels/lumbridge.json');
```

The sandbox is `scene.export(path)`'s and not a second one: a path that climbs out of the assets
directory throws, a leading `/` means that directory rather than the disk's root, and nothing outside
it is ever written. Without `--assets` the path is used as written, exactly as `scene.export`'s is.

Answers the path it actually wrote to, the same way `scene.export` answers with `path` — useful when
a caller built the path and wants to show a player, or a log, where it landed.

A folder on the way that is not there yet is made, as `three.save` makes its own: the first save into
a fresh `levels/` is the ordinary case rather than a mistake, and the sandbox has already said the path
is inside the assets directory before anything is created. `scene.export` does the same.

The same 4 MB `three.readText` stops at bounds this too: a file this writes has to be a file that
reads back, and a second, larger limit would make that false.

## three.level

A placement list over a kit — a piece and a transform per row, read with `three.readJSON` and
written with `three.writeJSON`:

```json
{
  "kit": "kit/buildings.glb",
  "rows": [
    { "id": "wall_1", "piece": "wall_stone", "position": [0, 0, 0], "rotation": [0, 0, 0] },
    { "id": "wall_2", "piece": "wall_stone", "position": [3, 0, 0], "rotation": [0, 1.5707963, 0],
      "snap": { "to": "wall_1", "side": "+x", "axes": { "z": "min" } } }
  ]
}
```

`kit` is the default asset path, in the form `three.load` takes; a row may carry its own `"asset"`
to place a piece from another file. `piece` is a node name the way `asset.node(name)` takes it, and
`id` is a string unique within the file — a duplicate, or a `snap.to` naming no earlier row, throws.
`position` and `rotation` are what the object's own properties read back as after placement, always
present; `scale` defaults to `[1, 1, 1]`. `snap` is optional: `{ to, side, axes }`, exactly what
`object.snapTo`'s three arguments take, and a freehand row — no `snap` — never moves on its own.

A `.glb` bakes geometry in, so re-exporting a kit does not move a level built from it — and a
transform alone bakes the *placement* the same way, one level up: re-export the kit with a taller
wall and the storey snapped on top of it stays where it was. So a row placed by a snap carries the
snap, not just where it landed. `three.level.load(path, parent)` takes the written transforms as
they are and asks nothing, which is what makes a saved level exactly reproducible. Pass
`{ refit: true }` to replay every snapped row's `snapTo` instead, in file order, against the kit as
it is now — the wall regrows, the storey lifts with it — while a freehand row is left exactly where
the file says either way.

- `three.level.load(path, parent, options = {})` — reads the file, places every row under `parent`,
  and returns a `Level`. `null` for a file that is not there, like `three.readJSON`.
- `three.level.save(path, level)` — writes `level` back, each row's transform read fresh off its
  object. Answers the path it actually wrote to.
- `three.level.create(kit)` — an empty `Level`, for an editor that starts from nothing.

```js
const scene = new three.Scene();
const level = three.level.load('levels/lumbridge.json', scene);
const wall = level.objects.get('wall_2');
wall.position.x += 0.3;
three.level.save('levels/lumbridge.json', level);
```

`scene.export(path)` is still how a finished level becomes a `.glb` — `three.level` is the file that
placed it there in the first place, and the one an agent or a person keeps editing afterwards.

## scene.export(path)

Write the scene to a `.glb`. Answers with `{ path, meshes, entries, materials, images, nodes,
instances, batches, skipped, shaded, bakedImages, bakedColors, layers, bytes }`. A folder on the way
that is not there yet is made, as `three.writeText` makes one.

One mesh per unique (asset, mesh), so a thousand walls from one kit are one mesh in the file exactly
as they are one draw call in the frame.

Sibling copies of one shape become a single node carrying an array of transforms —
EXT_mesh_gpu_instancing, which any glTF reader can place — with a `_COLOR_0` array holding each
copy's `mesh.color`, so a scene of many colours reloads as the one draw call it drew as. `batches`
counts the nodes written that way.

- A copy with no sibling drawing the same shape keeps its name and its own material, and groups are
  never collapsed. Node names survive, and a mesh takes the name of the node that draws it when exactly
  one node does — a shape several nodes share keeps its geometry's name instead, since one name cannot
  stand for all of them, and what the shape was is kept beside it either way in `extras.geometryName`.
  So a kit written this way is read back with `asset.node(name)`, one named Group per piece, and with
  `asset.mesh(name)` for the pieces that are a single mesh.
- Siblings sharing a shape but not a material do not batch: a colour travels per copy in `_COLOR_0`,
  but a texture, a blend mode and a layer stack have no per-copy channel.
- Copies made with `asset.instantiate()` are not siblings — each arrives in its own group — so they
  do not batch. Pass `{ flatten: true }` to batch every copy of a shape in world space instead,
  giving up the hierarchy and the copies' names to do it.

Images are written once and shared across every file they came from. Under `--assets` the path is
inside the game directory and cannot climb out, as `three.load`'s is.

Helpers and hidden subtrees are not in the file (`skipped` counts them), and a ShaderMaterial is not
either, because it is a Slang pipeline and glTF describes surfaces rather than programs — those
meshes export with the base colour and texture their geometry carries, and `shaded` counts them.

Pass `{ bake: true }` to get the shaders back. Each ShaderMaterial body is run over its own mesh's uv
layout and read off the device, so what the frame showed reaches the file: a `baseColorTexture` where
the answer varies across the surface, a `baseColorFactor` where it turns out to be one colour, and
`alphaMode` MASK where the body discards, so leaves and netting come back as the shapes they cut.
Without it, a scene whose character is thirteen shaders exports as a correct scene in a single grey —
the tell is nine materials all carrying the same `baseColorFactor`.

- `bakedImages` and `bakedColors` count the copies it managed; whatever is left is still in `shaded`,
  since a mesh with no uvs has no layout to rasterise into.
- `true` bakes at 512 texels a side; a number picks another, 16 to 4096.
- The cost is one render, one readback and one PNG per bake, and a body reading `s.position` needs one
  per node rather than one per shape. On a 2909-copy scene of world-space shaders that is 308 images:
  14 MB at 256, 22 MB at 512, 44 MB at 1024, against 9.4 MB with no shading at all.
- It is unlit on purpose — a viewer lights what it loads, and a baked-in sun would land twice — and it
  needs a GPU, which the rest of export does not.
- A bake never splits a batch, so copies inside an instanced node share their batch's answer.

Material layer stacks are the exception to that last part. A mesh loaded from a `.glb` carrying
`CUSTOM_materials_layers` is written back with the stack it came in with; a `three.LayeredMaterial`
built in a script is written from the description it was constructed with, images read back off the
device. Either way the stack survives, and `layers` counts the records. The `COLOR_0` a VERTEX_COLOR
mask reads goes into the file beside them. A script stack takes precedence when a mesh has both,
because that is what the frame drew with, and changing a layer's map or animated tint after
construction is picked up — the export reads live samplers and uniforms.

The scene around the meshes goes too: the camera as a glTF camera and every light as a
KHR_lights_punctual directional light, each on its own node, so the file opens framed and lit the way
three had it. The ambient floor has no glTF equivalent and is the one thing lost. Materials carry
`side` as `doubleSided`, `repeat` and `offset` as KHR_texture_transform, and a source material's
normal, occlusion and emissive maps with the metalness and roughness the specular term drew them
with. Reflectance has no glTF slot that round trips, and lines are not written yet.

## three.renderSize()

`{ width, height }` of the offscreen image — what `pick()` counts in and what a returned PNG is.
`three.window` is how big the window showing it is, and the two are free to differ.
`three.setRenderSize(width, height)` moves this one.

## three.setRenderSize(width, height)

Pin the render size instead of letting it follow the window.

By default the offscreen target tracks the window's drawable — drag an edge, call
`three.window.resize`, go fullscreen, and the picture moves with it. This is the escape hatch, and the
reason for it is performance: a target below the window is upscaled to fill it, which is the
render-scale slider a settings screen has. `three.setRenderSize(null)` gives the follow back.

After it, `three.renderSize()`, the PNG a screenshot returns and the coordinates `scene.pick(x, y)`
counts in are all the new size, and a post chain's images are rebuilt at it.

Returns true when it has already happened and false when it is queued. Called from inside the
animation loop it takes effect between that frame and the next, because the images it frees are the
ones that frame is drawing into — the same deferral `three.reload()` and `three.quit()` use. Called
from a booting script or an MCP tool call it is immediate, so the very next screenshot is the new
size. Either way, read the size back on a later frame rather than on the next line.

A size the device will not allocate throws, and the old target is still there and still being drawn.
A run with no host loop never performs a queued one. Sizes are 1 to 16384 a side.

## three.configure(options)

What a game declares about itself, at the top of `main.js`: `{ title, fullscreen, saveDir }`. Every
key is optional and anything left out is left alone.

```js
three.configure({ title: 'Wumpa Quest', fullscreen: false, saveDir: 'wumpa-quest' });
```

There are no command-line flags for these — a player never sees a command line, and a settings screen
has to change the same things at runtime — so `title` and `fullscreen` are live properties on
`three.window` as well, and this is the one call that sets them before the first frame.

`saveDir` is boot-only and has no property beside it, because moving it mid-run would strand
everything already written. It is a folder name and not a path; a separator in it is refused.

Returns `{ title, fullscreen, saveDir }` as they stand after the call, so a boot log can print one
accurate line. Under `--headless` the window half is remembered and does nothing.

## three.save

Read and write the game's own save folder — the one place a script may write outside its assets
directory.

- `write(name, value)` / `read(name)` — JSON.
- `writeText(name, string)` / `readText(name)` — a string.
- `writeBytes(name, bytes)` / `readBytes(name)` — a Uint8Array.
- `list()` — every save in the folder. `remove(name)` deletes one, answering false for a slot that
  was not there.
- `path` — where the folder actually is, or null when nothing has named one.

The folder is `<application data>/three.c3/<name>`, named by `three.configure({ saveDir })` or taken
from the assets directory's own name: `~/Library/Application Support` on macOS, `%AppData%` on
Windows, `$XDG_CONFIG_HOME` or `~/.config` elsewhere. Deliberately not the cache directory the
compiled shaders go in — a disk cleaner may empty that one.

A save is a name, not a path: letters, digits, dash, underscore and dot, at most 64, not starting
with a dot. There are no subdirectories and no way to leave the folder, so `'a/b'` and `'../escape'`
throw rather than resolving.

Reading something never written answers null rather than throwing, because that is every game's first
run, and `list()` is `[]` before a folder has even been named, so a load menu needs no guard. A
`--script` or `--mcp` run has no assets directory to be named after: saving there throws until
`three.configure` names a folder.

## three.window

The window: `width`, `height`, `scale`, `resize(width, height)`, `title` and `fullscreen`.

`width` and `height` are device pixels, read off the drawable so they stay current through a live
resize drag; `scale` is device pixels per logical point — 1.0 on an ordinary display, 2.0 on a retina
one. `resize` takes those same device pixels, so asking for a size and reading it back agrees, and it
answers with whether there was a window to ask.

`title` is writable at any time — `three.configure` names it at boot and this is what a level change
or a pause menu uses — and reads back what was last set even under `--headless`.

`fullscreen` is a request in both directions: macOS animates into its own space over about half a
second, a Wayland compositor answers with a configure some frames later, and an X11 window manager
may refuse outright. Read it back on a later frame.

The picture follows the window: the offscreen target moves to the new drawable, so resizing or going
fullscreen renders more pixels rather than stretching the ones there were, and `three.renderSize()`,
the PNG a screenshot returns and the coordinates `scene.pick(x, y)` counts in all move with it. The
interface is laid out in those same pixels and is re-laid-out along with them, so a maximised window
gets a full-size menu bar and panels rather than ones sized for whatever the window opened at.
`three.setRenderSize` pins it when a game wants a render scale of its own, and resizing past a pinned
size says so in the run's warnings.

Resize is a request, not a setting: the new size turns up on a later frame rather than on the next
line, so read `three.window.width` back from inside the animation callback.

On Wayland the size never reads back — the surface answers "whatever the swapchain asks for" — so the
drawable stays what the process booted at and the compositor scales it. X11, macOS and Windows track
it. Under `--headless` sizes are zero, `fullscreen` is false and `resize` returns false.

## three.getApiDocs(options)

This documentation, four ways.

- No argument — the index: the summary, every difference from Three.js, the stats block, the key
  names, the examples, and the names of the classes and functions. About a quarter of the whole, and
  the part read every time.
- `{ search: "shadow" }` — the grep: every entry whose name or prose mentions a word, in full, keyed
  by the path that asks for it again.
- `{ section: "classes.ShaderMaterial" }` — one entry or one whole section. A bare `"ShaderMaterial"`
  is found too.
- `{ all: true }` — everything at once.

Over MCP these are `get_api_docs`'s arguments, plus a `path` that writes the whole surface to a
Markdown file — one heading per entry — which is how you grep it with your own tools.

## three.searchDocs(term)

Where does the API mention X, over the whole documentation rather than only the differences.

Answers `{ query, matches, entries }`, where `entries` maps a path like `classes.ConvexGeometry` or
`functions.three.load(path)` to the text at it. One answer is capped, and anything that did not fit
is named in `notShown` rather than dropped silently.

`three.searchDocs("keyboard")` finds the headless-has-no-keyboard note without dumping the whole
documentation object. Same thing as `three.getApiDocs({ search: term })`.

## three.budget

How long this script may run before the interrupt stops it, in milliseconds. 30,000 by default
through `run_script` and 5,000 everywhere else — a tool call is already asynchronous to whoever made
it, where a window is somebody watching a frame.

Raise it to simulate, not to build: five seconds is generous for assembling a scene and short for
stepping one. Raising it applies to the run that raises it, because a script does not know it needs
longer until it is already running.

Ten minutes is the ceiling and asking for more clamps rather than throws; zero or negative throws,
because there is no way to turn the interrupt off. It does not reach the animation callback, which
keeps its own 100 ms so that one slow frame is a stutter rather than a hang.

## three.budget (a COLD scene build over the budget)

A `run_script` that rebuilds a scene from scratch can still run past 30,000 ms, and the error names
the fix.

On a fresh `--mcp` backend the first build pays for shader compiles and texture uploads that a warm
(`--script`-preloaded) backend already did, so it can cross the budget even when the same script
returns in time on a second call.

The fix is one line at the top of the script, before any build: `three.budget = 60000;`. Better
still, preload the scene so the build runs outside the budget — launch the backend with
`--script scenes/mine.js` and let `run_script` move the character rather than rebuild it. Reading
`three.budget` back answers the current limit.

## toJSON() / toString()

What `JSON.stringify` sees, and therefore what comes back in the `value` field when you return an
object from a script. Objects report their name, transform and children; a Vector3 reports
`[x, y, z]`; a ShaderMaterial reports its fragment and uniforms.

# Measuring and placing

## object.align(axis, edge, at)

Move an object along one axis until one face of its box sits at a coordinate. The verb that replaces
arithmetic on a hand-copied size table.

```js
piece.align('y', 'min', 0);       // stand it on the ground
piece.align('z', 'max', 10);      // front face at z = 10
```

- `edge` is `'min'`, `'center'` or `'max'` — which of this object's faces to put there.
- Everything is in the parent's frame, which is the frame a script writes positions in, and it works
  before `add()`.
- Only `position` moves. Rotation and scale are inputs to where the box is, so set them first — a
  quarter-turned piece is measured turned.

## object.snapTo(other, side, axes)

Put this piece on one side of another one, touching. The verb a kit is built with, and the one that
replaces a size table.

```js
lean.snapTo(hall, '+z', { x: 'center', y: 'min' });
tiles.snapTo(course, '+y', { gap: -0.05 });
```

- **An axis nobody names does not move.** A piece straight off the loader stands at the origin, so
  `lean.snapTo(hall, '+z')` on its own lands it at x = 0 — name the other two axes, or know why not.
- `side` is exactly one of `'+x'`, `'-x'`, `'+y'`, `'-y'`, `'+z'`, `'-z'`: which side of the other
  object this piece goes on. `'+z'` puts this box's min face on that box's max face, `'-z'` the
  mirror of it. One direction names both faces, which is why the verb reads as a placement rather
  than a puzzle. Anything else that is a string is tried as a marker name instead — see below — and
  anything that is not even a string is refused with the six faces listed.
- **Or the name of a marker both pieces carry**, for a mating surface that is not one of the six
  faces — two roof slopes meeting along a pitch, where the boxes overlap by the slab's thickness and
  neither piece has a face for the other to touch. A marker is a leaf node with no mesh: the empty a
  `.glb` kit ships for a connection point, the same way a Blender kit does, or a plain `Object3D` a
  script named by hand. `slope.snapTo(other, 'ridge')` finds the descendant named `ridge` in each
  piece and moves this object so the two markers' world positions coincide. **This never rotates** —
  set `rotation` first, exactly as before a box snap — and since the two markers decide all three
  axes, `axes` and `gap` are refused rather than silently ignored; offset afterwards with
  `position.x += ...`. A marker missing from either piece is refused with the marker names each piece
  actually has.
- The other two axes take one word for both faces — `'min'`, `'center'`, `'max'` — or the long
  `{ mine, theirs, offset }`, whose defaults are `min` against `max`. A post centred on a corner is
  `{ x: { mine: 'center', theirs: 'max' } }`.
- `gap` is a distance along the side, with `row`'s sign: positive leaves a gap, negative laps the
  pieces over each other, which is what a course of roof tiles is. It defaults to `0`, touching.
- Naming the side's own axis is refused — the side already said what that axis does — and so is a
  key that is not `x`, `y`, `z` or `gap`.
- The frame is not a choice. Siblings are measured with `boundsInParent()` in the frame they share;
  two objects under different parents are measured with `boundingBox()` in world space and the step
  is converted back into this object's own frame, which is exact whatever the ancestors are — a
  non-uniform scale and a rotation that is not a quarter turn included, because a translation goes
  through any invertible frame exactly. The world path needs both objects in a scene, costs two host
  calls where the sibling path costs none, and puts world-axis faces of world-axis boxes together:
  for a turned piece that is a looser box than the sibling path reads.
- Returns this object, so placements chain.

## object.alignTo(other, axes)

Flush with another object without touching it — a chimney on a ridge, a sign centred on a door. The
half of placing that a side would be a lie about.

```js
chimney.alignTo(ridge, { x: 'center' });
```

- One entry per axis, `x`, `y` or `z`, spelled exactly as `snapTo`'s: one word for both faces, or the
  long `{ mine, theirs, offset }`.
- **An axis nobody names does not move**, which is what makes this safe to reach for after a piece is
  already standing on the floor. A call that names no axis at all is refused rather than obeyed.
- There is no `axis`/`mine`/`theirs`/`offset` at the top level and no `world`: name the axes, and the
  frame is chosen the same way `snapTo` chooses it. A key it does not have is refused by name rather
  than quietly doing a default.
- For a placement that touches, this is the wrong verb — `snapTo(other, '+y')` says it in one word.

## object.row(axis, pieces, options)

Place pieces edge to edge along one axis — a wall run, a floor, a fence line. The commonest thing a
kit is asked for, and the one a script otherwise writes as a loop over a step it measured itself.

```js
wall.row('x', panels, { at: -3 });      // butted, from x = -3
fence.row('z', posts, { gap: 1.4 });    // spaced, from where the first post already stands
```

- **The step is measured from each piece**, never assumed, so a run of pieces that are not all the
  same size still closes up, and a piece turned a quarter turn steps by the side it now presents.
- `at` is where the run's low face goes. Left out, the run starts at the first piece's own low face —
  "these follow that one".
- `gap` is added to each measured step: `0` butts the pieces, a negative one laps them over each
  other (a course of roof tiles), a positive one spaces them (a fence).
- Only the run axis moves, and a piece that is not a child of this object yet is added to it.
- On the parent because a run has a cursor and the cursor belongs to whoever owns the sequence. The
  other half — "put me after that one" — is already one `snapTo` call. For a run that grows the
  other way, reverse the list.

# Spatial queries

## three.query.sphere(centre, radius, into)

Every drawable node whose bounding box reaches within `radius` of a point.

With no third argument it answers with an Array of objects; with a `three.query.buffer(n)` it fills
that and answers with a count, which is the form to use in a loop.

A broad-phase answer: the test is against each node's box, so something whose box reaches and whose
triangles do not is included. Invisible nodes are left out, as they are for picking.

## three.query.box(box, into)

The same, for a Box3, a `{ min, max }` or a flat `[minX, minY, minZ, maxX, maxY, maxZ]`.

## three.query.buffer(capacity)

A reusable answer for the flat form of every query verb. Make it once, outside the loop.

It holds `.handles` (an Int32Array of index/generation pairs), `.count`, `.full` — true when the query
filled it, which means there may be more — and `.objects()`, which resolves them all in one walk of
the scene. A script that only wants to count what is nearby never has to resolve anything, which is
most of why this shape exists.

## three.query.raycastAll(origin, direction, options)

Every node a ray hits, not only the nearest — shooting through a window, listing what is behind what,
a laser that stops at the first solid thing rather than at the first thing. Options are
`{ maxDistance, limit }`.

Not sorted by distance: sorting means holding every hit before answering, and a caller who wants the
nearest should call `scene.raycast`, which is cheaper than sorting because it can stop walking.

## three.query.sweep(from, to, options)

Move a sphere or an upright capsule from one point to another and report the first thing it touches,
or null.

`{ radius }` alone is a sphere; adding `{ height }` makes it a capsule that tall overall; `{ ignore }`
leaves objects out, taking an object or an array of them and leaving each one's whole subtree out.

The hit carries `fraction` — where along the motion it happened — so the safe position is
`from + (to - from) * fraction`.

This is the same narrow phase `three.moveAndSlide` is built out of, so a wall this reports and a wall
a character slides along cannot be two different walls. There is no orientation argument: everything
this is for stands up.

## three.moveAndSlide(position, motion, options)

The character controller. Sweeps a capsule from `position` by `motion`, slides along whatever it hits,
climbs a ledge under the step height, and answers with
`{ position, remaining, grounded, slope, ground, hit, normal, stepped, slides }`.

Options are `{ radius, height, step, slope, skin, snap, ignore }`:

- `height` is the whole capsule.
- `step` is how high a ledge may be.
- `slope` in degrees is the steepest ground that still counts as ground.
- `snap` is how far the floor may drop under the feet in one frame and still be walked down rather
  than fallen off.

It integrates nothing: gravity, the velocity and the jump are yours. A frame is
`three.moveAndSlide(where, [vx * dt, vy * dt, vz * dt], opts)` followed by copying `r.position` onto
whatever you are driving. It is kinematic and touches no rigidbody.

Pass the character's own object as `ignore`, and pass the Group rather than one mesh out of it:
`ignore` leaves the object's whole subtree out, so a character built from a body, a head and four
limbs does not collide with its own chest. It takes an array too, for up to eight things — a ninth
throws rather than being silently dropped. It is per call; a thing that should never be collision
geometry for anybody is `object.collides = false`.

## three.batch(objects, options)

A Float32Array-shaped bulk write over many nodes. `batch.positions` is three floats per object, seeded
from where they are now; `batch.flush()` sends the lot in one crossing and answers with how many
landed. With `{ trs: true }` the stride is ten — position, an xyzw quaternion, then scale.

A member that has left the scene is skipped rather than throwing, because a crowd where one agent was
removed this frame is ordinary.

Do not reach for this to move a dozen things: five hundred ordinary position writes are three per cent
of a frame, and the trigger for this is about two thousand nodes a frame.

## three.moveAndSlideAll(positions, motions, options) / three.moveBuffer(n) / three.moveResult

`three.moveAndSlide` for a whole crowd, in one call — the same controller and the same sweeps. It
exists for the shape of the answer rather than for the crossing: the single form measures 8.32 µs per
agent and this one 1.43 µs, so two hundred agents cost 0.29 ms of a fixed step instead of 1.66 ms. What
went away is a JavaScript result object per agent.

- `positions` is the capsule centre, three floats per agent, read and written in place — it is your
  position column, so there is nothing to copy back.
- `motions` is the whole step's motion, three floats per agent, read.

Options are `{ radius, height, step, slope, skin, snap, ignore, self, results }` — the same six numbers
the single form takes, one set for the whole crowd, because a crowd is one agent size.

- `self` is how an agent stops colliding with its own mesh, and it is a column rather than one object:
  two ints per agent, that agent's node and generation, whose whole subtree it passes through.
  `three.batch(objects).handles` is already exactly that array; an array of objects also works.
- `ignore` is still the shared set — the lift everybody rides — and takes at most seven alongside a
  `self` column, because the eighth slot is the agent itself.
- `results` is optional and is a `three.moveBuffer(n)`: eight floats per agent, laid out by
  `three.moveResult` — `remaining` at 0, `normal` at 3, `slope` at 6, and a flags float at 7 holding
  `moveResult.GROUNDED | STEPPED | TOUCHED`. Leave it out and only the positions are written.

Everyone moves at once: every agent is swept against the world as it was when the call started, so
agent 3 does not see agent 2's new position. Resolving in array order instead would make the answer
depend on how you happened to store your crowd, and `three.steer`'s separation already assumes
simultaneity. Two agents can therefore end a step overlapping; separation keeps that rare and the next
step's depenetration resolves it.

It answers with no node handles. The single form reports `ground` and `hit`; a flat float array cannot,
and "what am I standing on" is a moving-platform question belonging to the one character riding the
platform — that character calls `three.moveAndSlide`.

## scene.pick(x, y)

What is under a pixel of the rendered image, counted from its top-left corner. Answers with an
intersection or null. Needs a GPU device.

## scene.raycast(origin, direction)

What a world-space ray hits. Either vector may be a Vector3, an `{x, y, z}` or an `[x, y, z]`, and the
direction need not be normalised. Answers with an intersection or null.

# Navigation

## three.nav.bake(options)

Voxelize the scene's standing room, so `three.nav.path` and `three.nav.field` have a graph to work
over. `{ cell, radius, height, slope, bounds }` — every one a property of the agent except the last.

Call it after the level is built. Nothing bakes on demand, because that would hide a cost and rebake on
the first call after anything moved.

`cell` decides everything: it is the resolution and also the largest step that can be climbed, because
two cells are connected when they are adjacent and one cell up. Half a metre is a generous stair and a
cheap bake; a finer one costs as the cube.

Answers with the same object `stats()` does, or null when the region held no standing room, which is an
answer and not an error. A second bake replaces the first.

The bake belongs to its scene — `scene.nav` is the one that does, `three.nav` is whichever scene is
being rendered — so it survives a switch, and the next level can be baked before it is shown.

Check `components` on what comes back: anything above 1 is a level cut into islands, and every other
number will look healthy while half your agents stand still.

## three.nav.stats()

What the last bake produced and what it cost: `{ cell, radius, height, slope, voxels, solid, floor,
walkable, components, largest, bakeMs, bounds }`, or null if there has not been one.

`bakeMs` and `voxels` decide whether baking is a level-boundary operation or a loading screen for your
level rather than for a reference one.

`components` is the one to check, and it is not a cost: it is how many disjoint regions the standing
room came out in, with `largest` the size of the biggest. Every other number here is a total, and a
total cannot tell a level an agent can cross from the same level in pieces — a doorway one cell too
narrow, a step one cell too high or a ramp that does not quite reach all leave `walkable` looking right,
`field()` returning a live field rather than null, and `direction()` answering `(0, 0, 0)` for every
agent on the wrong side of the break. Above 1 means "there is no path" is the honest answer for some
pairs of points, and the usual cause is a `cell` too coarse for the geometry.

## three.nav.path(from, to, options)

One agent, one route: an Array of Vector3 waypoints on the walking surface, starting at the point given,
or empty when there is no route. `{ limit }` caps the waypoint count.

The straight lines between them have been checked with a capsule sweep at the agent's own size, so a
corner it cannot physically round has not been cut and the path does not look like it is walking cell
centres.

This solves a whole field and throws it away — right for a wanderer replanning every few seconds, and
the thing `three.nav.field` exists to replace for a crowd.

## three.nav.field(goals)

Solve towards one or more goals and keep the answer — the verb a crowd uses.

Takes a point or an array of points. Many goals is not several routes: it is one field whose value is
the distance to the nearest of them, which is what a crowd heading for whichever exit is closest wants.

Returns a NavField with `direction(point)` — a unit XZ vector, or zero for nowhere to go —
`cost(point)`, which is Infinity for unreachable, `reaches(point)` and `dispose()`.

Returns null when no goal landed on a walkable cell, which is the usual way a goal is wrong: given at
the height of the floor's underside, inside a wall, or outside the baked region.

Feed the field to `three.steer` rather than calling `direction()` in a loop.

## three.steer(positions, velocities, options)

Seek, arrive and separation over a whole crowd in one crossing. `positions` and `velocities` are
Float32Arrays of three floats per agent — the first read, the second written.

Options are `{ field, goal, maxSpeed, arrive, separation, separationWeight }`. A field wins over a goal,
because a field already knows the way round a wall. `arrive` is how far out an agent starts slowing, and
0 never slows — which is how a crowd ends up orbiting a door.

What comes back is a desired velocity: integrate it yourself, and feed it to `three.moveAndSlide` for
agents that collide or add it straight on for agents that do not.

# Math

## three.catmullRom(points, options)

A smooth curve through sparse control points, as a dense polyline — the path half of the curve pair
(RibbonGeometry is the mesh half).

Pass `[[x, z], ...]` or `{x, z}` control points and get back `[[x, z], ...]` with `samples` points per
control segment (default 16). Type is `'centripetal'` (default), `'chordal'` or `'uniform'`;
centripetal passes through every point without swinging wide of a tight one, which is what a
hand-written road path is. The first and last control points are reproduced exactly.

Feed the result to `field.carve` / `field.stroke` / a scatter avoid corridor so a sparse polyline stops
being a black-and-white zigzag, or pass the raw control points to a RibbonGeometry, which curves them
itself.

## three.clamp(v, min, max) / clamp01(v) / lerp(x, y, t) / inverseLerp(x, y, v) / mapLinear(x, a1, a2, b1, b2)

The scalar block, with Three.js's MathUtils names and Three.js's argument order.

`clamp01` is GLSL's saturate and has no Three.js equivalent. `inverseLerp` answers 0 when `x` and `y`
are equal, because the honest alternative is a division by zero that reads as the whole gradient
disappearing.

These stay in JavaScript on purpose: a host call that allocates in order to answer arithmetic measures
185 ns against the 70 ns of the JavaScript it replaced.

## three.smoothstep(x, min, max) / smootherstep(x, min, max) / band(x, lo, hi)

The 0..1 ramp with flat ends — and the argument order is Three.js's, not GLSL's. GLSL is
`smoothstep(edge0, edge1, x)`; this is `smoothstep(x, min, max)`, value first. Every shader body in this
project uses the GLSL order and every script uses this one, so the two sit a few lines apart in the same
file and swapping them is silent: the answer is still a number in 0..1, just the wrong one.

`smootherstep` has a zero second derivative at both ends (Perlin's), and is what to use when a smoothstep
ramp still shows a crease where it meets the flat part.

`band` is a smooth bump — 0 outside `lo..hi`, 1 in the middle — with no Three.js equivalent. It is the
splat-mask verb, and the reason a layered terrain reads as bands of material rather than one gradient.

## three.pingpong(x, length) / euclideanModulo(n, m) / degToRad(d) / radToDeg(r)

All Three.js MathUtils names.

`euclideanModulo` answers with the sign of the divisor, so `-1 % 4` is 3 rather than -1 — which is what a
wrap-around index or a tiling coordinate wants, because JavaScript's `%` is a remainder and the negative
half of every tiled texture is where that shows. `pingpong` ramps up to `length` and back down forever.

## three.moveTowards(current, target, maxDelta) / moveTowardsAngle(current, target, maxDelta)

Step towards a target at a fixed rate, stopping exactly on it — the linear sibling of `three.damp`.

`damp` closes a fraction of the gap per second, so it is fastest at the start and never quite arrives,
which is right for a camera easing onto a target. This closes `maxDelta` per call and lands exactly, which
is what a turn-rate limit, a reload timer, a fuel gauge and an ammo counter want: anything whose speed is a
rule rather than a feel.

`maxDelta` is a distance, so it is `rate * dt`. `moveTowardsAngle` is the same, taking the short way round
a circle.

## three.wrapAngle(radians) / angleDelta(from, to)

The seam at ±pi, named.

`wrapAngle` folds an angle into `[-pi, pi)` — half open at the top, so exactly pi comes back as -pi, which
is the same heading.

`angleDelta(from, to)` is the short way between two headings, signed. A heading of +3.1 against a target of
-3.1 is 0.08 radians apart this way and 6.2 the straight way, and a character told to turn 6.2 radians
spins a full circle to arrive somewhere it was already almost pointing.

`three.dampAngle` and `three.moveTowardsAngle` are both written in terms of `angleDelta`, so there is one
spelling of the wrap rather than three.

## three.mixColor(a, b, t) / tintColor(colour, k)

Colour arithmetic over whatever `mesh.color` takes — a hex like `0xff8800`, an `[r, g, b]`, an
`[r, g, b, a]` or an `{r, g, b}` — answering with four components, so the result feeds straight back into
`mesh.color`, a uniform, or another one of these.

`t` is not clamped, for the same reason `lerp` does not clamp. `tintColor` scales brightness and leaves
alpha alone, because a tint that also faded the thing out would be a surprise.

## three.seed(n) / randFloat(low, high) / randInt(low, high) / randFloatSpread(range)

Randomness that can be replayed. These keep Three.js's names and do not call `Math.random`: they draw from
a seeded stream `three.seed(n)` resets.

That is a deliberate divergence. `Math.random` throws away the determinism the rest of the engine goes to
some trouble to have — the fixed step, the solver's own accumulator and `state_hash` all exist so that the
same inputs produce the same frame, and one `Math.random()` in the gameplay layer costs all of it: a bug
that reproduces on the tester's machine and not on yours, with no way to bisect. A script that wants an
unrepeatable number still has `Math.random`.

`randInt` is inclusive at both ends, as Three.js's is. `new three.Random(seed)` is the same generator owned
by the caller, for when two systems must not perturb each other's sequence.

## three.hash(x, y, seed) / noise2(x, y, options) / fbm2(x, y, options)

Noise, sampled at a point rather than baked into a grid — which is the shape that composes: the same call
fills a texture in a double loop, feeds `field.fill((x, z) => ...)` for terrain, and answers a single spawn
test.

- `hash` is three ints in and a number in 0..1 out, and the same three always answer the same.
- `noise2` is smooth value noise on a unit lattice, one feature per unit of x and y, taking
  `{ seed, period }`.
- `fbm2` is `octaves` layers of it, each twice as fine and half as strong, normalized back to 0..1 — the
  verb behind every generated rock face, bark, dirt and cloud in `examples/` — taking
  `{ octaves, seed, period, lacunarity, gain }`.

`period` is what makes it tile: pass the number of cells across the image and the left edge meets the right.
`fbm2` tiles correctly only because each octave's period is scaled with its frequency, which is the part
that is wrong when it is written out by hand — and the reason a hand-rolled tiling fbm shows a seam at
exactly one octave's worth of the image.

## three.damp(current, target, lambda, dt)

Move `current` towards `target` by a fixed fraction of the remaining distance per second.

`lambda` is the rate — 1 is lazy, 5 is a normal follow, 20 is nearly rigid — and `dt` is in seconds:
`three.clock.dt` as it comes. Three.js spells this `MathUtils.damp`.

`three.dampAngle` is the same taking the short way round a circle, which is what a heading needs and what
the plain one gets wrong at exactly the place a mouse look crosses constantly.

## three.smoothDamp(current, target, state, smoothTime, dt, maxSpeed)

A critically damped spring — the one to reach for when `damp` overshoots the feel you wanted. The difference
is momentum: `damp` is fastest at the start and asymptotically slow at the end, right for a camera easing
onto a target and wrong for anything that should look accelerated.

`state` is an object this writes `.velocity` into, and it must outlive the frame. One created inside the
loop is a spring re-launched from rest sixty times a second, which looks exactly like `damp` with a worse
constant and is the one way to use this and see nothing.

`smoothTime` is roughly how long the move takes, in seconds.

## new three.CatmullRomCurve3(points, closed, curveType, tension)

The three-dimensional half of the curve pair, and the one a loop samples rather than a bake consumes: a
camera rail, a patrol route, a rope. Three.js's class and method names — `getPoint(t)`, `getPointAt(u)`,
`getTangent(t)`, `getLength()`, `getPoints(n)`, `getSpacedPoints(n)`.

`getPoint` and `getPointAt` are not the same function, and the gap between them is what makes hand-written
rail code look wrong. `t` is the curve's own parameter, spread evenly over the control segments, so an
object moving at a constant `t` per second speeds up through the widely spaced ones and crawls through the
close ones. `u` is spread evenly over the length, and that is the one anything moving wants.

`three.catmullRom` is the other half: a ground path, `[x, z]` in and a dense polyline out, for
`field.carve`, `field.stroke` and RibbonGeometry.

## three.scatter(options)

Where to put a hundred trees: `{ count, seed, onTerrain, bounds, spacing, minHeight, maxHeight, maxSlope,
avoid, accept }`.

Returns `[{ x, y, z, normal, index }]` — placements, not meshes, because the loop that turns a placement
into a mesh is three lines and the caller almost always wants to vary the colour or the scale per point.

- `onTerrain` is a TerrainGeometry or a Field and supplies the height and the normal; `bounds` defaults to
  that terrain's own extent.
- `avoid` takes `{ x, z, radius }` circles and `{ path, width }` corridors, so the same polyline that carved
  the river keeps the trees out of it.
- `maxSlope` is in degrees off flat.
- `spacing` is a minimum separation enforced by rejection, not a guarantee: the sampler gives up after a
  bounded number of tries and returns a shorter list rather than spinning, so read `.length`.

The same seed places the same points, which is what makes a screenshot comparable to yesterday's.

# Systems, entities and loops

## three.systems.step(name, fn, options) / frame / add / remove / enable / list / outline / report / clear / three.systemLoad(budgetMs)

The ordered system registry. `three.setFixedLoop` and `three.setAnimationLoop` each take one callback, so a
game with five things to do a frame has one function with five things in it — and that is what this replaces.

It makes nothing faster and is not meant to: every JavaScript-side data layout measured inside the noise
floor of the measurement itself. What it makes is a frame you can read and a slow one you can attribute.

The verb is the clock:

- `three.systems.step(name, fn)` is the fixed one — zero or more times a frame at `three.clock.fixedRate`,
  the same `dt` every call — and it is where the rules of the game go, because movement and collision drift
  when the step they integrate over does not.
- `three.systems.frame(name, fn)` is once per drawn frame, handed what that frame was actually worth, and it
  is where the camera, the fades and the uniform writes go.
- `add()` is the same thing with `{ phase }` left as an option, for when the phase is a variable.

They run in the order you register them. For the one system in a file that has to break that, name the
neighbour: `{ before: 'fire' }` or `{ after: 'Player.pose' }`, one name or a list, and a name registered
further down the file is fine. `{ first: true }` and `{ last: true }` are the two ends of the game's own
list — the engine's systems still bracket them, the rules drain ahead and the entity write-back behind. A
loop is refused where it is made; a name that matches nothing is said once and otherwise ignored. There is
also a numeric `{ order }`, which is what the engine's own systems use, but a game should not need it.

`outline()` prints the tick — `step  spawn → player → foes` on one line and `frame autopilot → fire` on the
next. Two lines because they are two lists: every step this frame owes runs before any frame system.

Adding a name that exists replaces it, so a re-run top level ends up with one copy of each system rather
than two.

Systems are handed seconds, unlike the animation callback, which keeps Three.js's milliseconds because it
keeps Three.js's name. `three.setAnimationLoop` and `three.setFixedLoop` are themselves systems now, under
the reserved names `animation` and `fixed`, which is why a script that has never heard of this is unaffected
and why a later `setAnimationLoop` cannot silently evict the whole list.

A system that throws does not stop the others — that is most of the point, because with one callback a throw
in the fruit code stops the camera. It is not swallowed either: the message names the system, repeats a few
times and then goes quiet, and `report()` keeps counting. Nothing is disabled behind your back.

- `list()` answers `[{ name, phase, order, enabled }]` in the order they run, steps first.
- `report()` answers `[{ name, phase, enabled, ms, peak, calls, errors }]` most expensive first, where `ms`
  is a rolling average of milliseconds per frame — so a fixed system that ran four times reports what all
  four cost — and `peak` is the worst frame since it started, because a mean of 0.4 ms hides a system that
  spends 9 ms once a second and that is the one a player feels.
- `three.systems.frameMs` is the total and `three.systemLoad(budgetMs)` is it as a 0..1 fraction.

Timing costs two `three.clock.wall` calls per system per call, about 3 µs a frame for ten systems;
`three.systems.profile = false` turns it off. `clear()` forgets everything, and `new three.Scene()`
deliberately does not — a Scene is the contents of the world and these are the rules it runs under.

## three.cooldown(duration, options)

A scalar timer for the `if (x > 0) x -= dt` pattern — a spin window, a hurt window, coyote time.

It is ticked by a lazily-registered `three.systems` entry rather than read off `three.clock.time`, because
the game clock advances once per host tick and a window shorter than one fixed step would see no time pass
across a multi-step catch-up frame. A paused clock still freezes it either way.

See the Cooldown class for `start`, `cancel`, `active`, `ready`, `recovering`, `remaining`, `progress` and
`elapsed`.

## three.Entity

The base class, and the shortest way to an entity: `class Critter extends three.Entity`, with no
registration call beside it.

The class registers itself on first use — a spawn, a rule, an `of()` — reading its own statics: `capacity`,
`columns`, `parent`, `body`, `volume`, `trigger`, `collides`, and `name` (the class name unless a static
`name` overrides it).

`super()` first in the constructor, and it is not a formality: that is where a bare `new Critter()` is
refused, which is the one check a class with no columns cannot get any other way. An untracked instance has
no node in the scene, no body in the solver and no place in the live list, and the first sign of it is a
thing that never appears.

Everything `three.track` installs is inherited: `spawn`, `of`, `remove`, `column`, `all`, `count`, `free`,
`compact`, `clear`, `dispose`, `on`, `off`, `system`, `pose`, `flush`, `sync`, `handles`, `transform`, and
iteration.

There is no `update()` to override, on purpose: continuous work is a system with a readable `{ order }`, and
a per-entity update method is the ninety-line animation callback again, once per class.

## three.track(Class, options)

The same registration as `three.Entity`, for a class that already has a parent and cannot extend it — the
options are the argument here and the statics there, and nothing else differs.

It answers with a Proxy that refuses a bare `new Class()`; capturing it is optional, because every static is
installed on the class itself.

It owns the object → instance map, the spawn ritual, the body, the volume, the live list and a compaction
registered as `<Class>.compact` — so `Class.of(hit.object)` is the instance and `c.remove()` is the whole
removal.

Options are `{ parent, columns, capacity, body, volume, trigger, collides, name }`:

- `columns` is `{ position: 3, motion: 3 }` and needs a `capacity`, because a column cannot grow without
  dangling every live window into it.
- `body` is what `three.physics.add` takes, or a function of the instance answering one.
- `volume` is `{ shape: 'capsule' | 'sphere' | 'box', radius, height | size, offset }` for an invisible
  kinematic body beside the drawn node, carried by `<Class>.follow`; `trigger` is the same with
  `trigger: true`.
- `collides` is written to every mesh in `this.object`'s subtree.
- `parent` hangs the nodes off a Group. It is refused alongside a `body` — a body-backed node has to be a
  direct child of the scene — but allowed alongside a `volume`, which is its own node and reads a world
  position to follow.

The constructor sets `this.object` to the Mesh or Group, and may write `this.position[0]` on line one: the
column slot exists before it runs.

`Class.spawn(...args)` is the only way in. `new Class()` throws, because an untracked instance has no slot,
no body and no place in the live list and every one of those failures is silent.

Statics: `spawn`, `of`, `remove`, `column(field)`, `all()`, `count`, `free`, `capacity`, `compact()`,
`clear()`, `dispose()`, `on()`, `off()`, and iteration — `for (const c of Critter)`. Instance hooks:
`onSpawn()` and `onRemove()`. There is no `update()` to override, for the reason given under `three.Entity`.

## three.instanceOf(object)

Which tracked instance owns this object — a drawn node, one of its child meshes, or a volume — or null.

It walks up the parent chain, because a raycast and a query answer with the leaf that was hit and an
assembled character is a Group of eleven meshes. The global reverse of `Class.of(object)`, and what a rule
keyed on "what are these two things" opens with.

## three.emit(a, verb, b)

The game raising its own event: `three.emit(player, 'use', door)` reaches `Door.on('use', Player, fn)`
exactly as a trigger reaches an `'enter'` rule, so a rule cannot tell whether a solver or a keypress raised
it. Either argument may be an instance or an Object3D.

It dispatches at once, where an engine event is queued and delivered by the `rules` system — a handler that
deletes a body from inside the solver is a hazard the game cannot see, and the game knows when it is safe
where the solver does not.

Answers with how many rules fired.

## three.rules()

Every registered rule: `{ name, event, subject, matcher, order, enabled, failures }`.

The pair-dispatch half of `three.systems.report()`, and how you find the rule that is throwing sixty times a
second after its message has stopped repeating in the log.

## three.setAnimationLoop(fn)

Run `fn(elapsedMs)` once per frame, or null to stop. Synchronous only. The next `run_script` reports how many
frames it ran, whether it is still running, and why it stopped if it did.

Only one callback exists: registering a second replaces the first.

It survives `new three.Scene()`, and so does the scene it was built for, so a callback holding meshes from an
older scene goes on moving them where nobody can see them — stop it yourself, or re-register it after the
swap. It only throws once that scene is disposed.

The milliseconds are the game clock (`three.clock.time * 1000`), so they stop when `three.clock.timeScale` is
0 and start at 0 on the first frame rather than carrying the boot.

## three.setFixedLoop(fn)

Run `fn(dt)` at a fixed rate — zero or more times per frame, as many as the clock owes at
`three.clock.fixedRate` (60 Hz by default), capped at eight.

`dt` is the same number every call, in seconds, which is what makes gameplay written against it produce the
same result on a slow machine as on a fast one. This is where movement, timers and rules belong;
`setAnimationLoop` is where drawing the consequence belongs.

The accumulator is the host's, not yours: one written in the animation callback spends the script budget
catching up and gets the callback stopped instead of stuttering.

Runs after the frame's physics and before the animation callback. Same rules as `setAnimationLoop` —
synchronous, one of them, null stops it.

## three.frame

How the frames have gone, and where the last one went: `{ running, ticks, overruns, ms }`.

`overruns` is how many frames spent more than 8 ms in JavaScript — half a 60 Hz frame, the point at which the
script has stopped leaving room for the draw it sets up. Nothing is logged when it happens, so this is the
number to read if you suspect hitching. Under `--mcp` alone it stays 0, because there an overrun stops the
callback instead of counting it.

`ms` is the last finished frame, split five ways — read it from inside a system and it describes the frame
before, which is complete. `{ handlers, fixed, frame, jobs }` are the four spans that add up to `total` and
are what the 8 ms is measured against:

- `handlers` — key, click and physics-trigger handlers.
- `fixed` — every fixed step this frame owed, together.
- `frame` — the animation callback and the frame-phase systems.
- `jobs` — one queued mesh upload and the microtasks it settled.

`solver` is outside `total`, because it is outside the budget: the physics step runs above the script's window
and is the host's own work, so a callback is never stopped or counted for it. It is reported because a frame
that spends 10 ms in the solver and 3 ms in script is a frame whose script is not the problem.

`three.systems.report()` is the rolling per-system version and the one to reach for next: this splits a frame
into four spans, that splits two of those spans by name.

# The clock

## three.clock.wall

The process's own monotonic clock, in milliseconds, and the one reading on `three.clock` that is not game
time.

Everything else there is scaled by `timeScale` and stops dead when paused, which is what makes
`x += speed * three.clock.dt` need no check — and what makes it useless for the one question a profiler asks,
because a system timed on the game clock reads zero while paused and four times its true cost in slow motion.

So this answers a different question: how long did that take, in real milliseconds, whatever the game clock
is doing. Two readings and a subtraction; a host call answering a number is 143 ns.
`three.systems.report()` is built on it and is usually what to reach for instead.

Its origin is when the JavaScript runtime opened and is shared with nothing else — differences are what it is
for. Read only.

## three.clock.time / three.clock.dt

The game clock, in seconds. `time` is what the frames have added up to and `dt` is what the frame being drawn
is worth — 0 before the first frame and 0 while paused, so `x += speed * three.clock.dt` needs no check for a
pause.

`dt` is clamped: a frame that took longer than 100 ms of wall time reports 100 ms, so a breakpoint or a long
tool call stutters rather than teleporting the world a second forward. Both are read-only.

## three.clock.timeScale / three.clock.paused

Wall time to game time: 1 is real time, 0.25 is slow motion, 3 is fast forward and 0 is paused.

It reaches everything — the clips, the physics, the fixed loop, the follow camera, the argument
`setAnimationLoop` is handed and `p.time` in a post body — because all of them are handed one delta rather
than reading a clock of their own.

Negative throws: nothing downstream of it can run backwards. `paused` is a read-only `timeScale === 0`; pause
by writing 0 and resume by writing the scale you want back.

## three.clock.advance(seconds)

Move the clock by hand, whatever the scale is — which is how a pause is single-stepped:
`three.clock.timeScale = 0` and then `advance(1 / 60)` is exactly one frame of world, clips and bodies and
fixed steps and `p.time` together.

It lands on the next frame rather than immediately, so under `--mcp` the order is `run_script`, a frame,
screenshot. Two runs that ask for the same amount draw the same picture, which is what makes a screenshot with
a post pass reproducible.

Calls accumulate into one frame rather than queueing frames, and that is the one way this verb can lie to you:
ten `advance(1 / 60)` before the next frame boundary is a single frame worth a sixth of a second, and the
solver catches up at most five steps and drops the rest while the fixed loop does the same at eight. Measured:
ten in one call moved the clock the full 0.167 s and dropped a falling body 1.41 units where ten stepped
frames drop it about 2.8. The time lands and the world does not.

To step n frames, call it once per frame boundary — under `--mcp` that is n round trips.

## three.clock.fixedRate / three.clock.fixedDelta

How many fixed steps a second of game time is worth — 60 by default, 1 to 240 — and the step that follows from
it, in seconds.

It does not change the solver's rate, which is 60 Hz and is the solver's business: a script asking for 30 Hz
gameplay must not quietly halve the accuracy of every contact in the scene.

# Input

## three.input.isDown(key)

Whether a key is held right now. Poll this in the animation callback for continuous movement — a held key
fires no repeat events.

## three.input.pressed(key) / released(key)

Whether the key went down (or up) during the frame being drawn. Meaningful inside the animation callback;
between frames it reports the last frame, which is almost always nothing.

## three.input.text

What was typed this frame, as UTF-8, with modifier chords, control characters and the function-key range
filtered out. The layout and the shift key are already applied, so this is what a text field wants rather
than the key map.

## three.input.keys()

Every key name there is. The same list the host searches, so it cannot be out of date.

## three.onKeyDown(key, fn) / three.onKeyUp(key, fn)

Call `fn(keyName)` once when the key goes down (or up), from inside the frame.

One handler per key per edge — binding again replaces, null unbinds, and up to 32 exist at a time.
Synchronous only, and stopped for good if it throws, exactly as the animation callback is.

Escape is the host's under `--debug`: it closes the window whatever a script binds, so bind a pause menu to
it and test the menu without that flag. In an ordinary run no key is reserved and escape is yours — the same
is true of shift+R, which reloads only under `--debug`.

## three.input.pointer

`{ x, y, dx, dy, inside, down, right, middle, clicked, scroll, scrollX }` — the whole mouse for this frame,
as one reading. Read it in the animation callback.

- `x` and `y` are in the rendered image's pixels counted from its top-left corner, which is what
  `scene.pick(x, y)` takes.
- `dx` and `dy` are how far the cursor moved since the previous frame, in those same pixels — what a mouse
  look is built out of, and not the same thing as differencing `x` yourself, which answers with the frame
  before the one being drawn. The browser calls them `movementX`/`movementY`. They keep reporting while the
  cursor is outside the window, and without pointer lock they stop at the edge of the screen.
- `scroll` is the wheel over this frame, positive away from the user (the opposite of the browser's
  `deltaY`), in notches or fractions of one from a trackpad, with `scrollX` the horizontal half. Both are
  zero on the frames nobody turned it.
- `down`, `right` and `middle` are the three buttons as latches rather than edges; `clicked` is the one edge.
- `inside` is false when the cursor has left the window, and everything is zero when there is no window.

## three.controls.enabled

Whether the mouse still reaches the camera. True by default; false stops the drag, the right-drag pan and the
wheel zoom, and stops the coast a flick leaves behind.

It is for a scene that drives the camera itself — a follow camera, a first-person look — which writes yaw,
pitch and target every frame and would otherwise have the turntable writing them again from whatever the hand
did. `three.camera.orbit()` and `three.camera.frameAll()` are unaffected, because a script writing the camera
on purpose is the thing being enabled rather than the thing being stopped.

A drag in progress is dropped rather than finished, and turning it back on waits for a fresh press instead of
resuming the old one. It reads back what was written to it with no window open, and it survives
`new three.Scene()` — following the camera rather than the background, because a game that took the mouse for
its own camera should not lose it at every level.

## three.onClick(fn)

Call `fn(hit, x, y)` once when the window is clicked, from inside the frame. `hit` is what is under the cursor
— the same intersection `scene.pick(x, y)` answers with, or null for a miss — so click-to-select is one call.

A click is a press and a release in the same place: dragging orbits the camera and does not fire this. One
handler; binding again replaces, null unbinds. Synchronous only, and stopped for good if it throws.

# Physics

## three.physics.add(object, options)

Give an object a body and answer with the object.

The description is `object.body` if it has one and `options` wins over it, so a scene can be described once
and tweaked at the call: `{ shape: 'box' | 'sphere' | 'capsule' | 'hull' | 'heightfield', mass: 1,
friction: 0.5, restitution: 0.2, kinematic: false, trigger: false }`. Mass 0 means static.

The object has to be in the scene already — a body is placed at a world position — and has to be a child of
the scene rather than of another object, because the solver works in world space and a parent transform would
fight it. A group draws nothing and so has no size to take a collider from; give the body to a mesh.

## three.physics.remove(object)

Take the body away, and answer whether there was one. A body removed while it is inside a trigger still emits
its exit event, so a script that destroys something in a trigger volume still hears it leave.

## three.physics.gravity

`[x, y, z]`, y-up, read and written as an array. Set once at boot; it is a world setting and not a transform,
which is why it is not a live Vector3. It is per scene, like the world it belongs to — `scene.physics.gravity`
for one that is not being rendered.

## three.physics.count

How many bodies the rendered scene's world holds. `scene.physics.count` is any scene's.

## three.physics.velocity(object)

`[lx, ly, lz, ax, ay, az]` — linear in world units per second, angular in radians per second — or null when
the object has no body.

Both at once because a script that wants one usually wants the other; null rather than a throw because this
gets asked in a loop over things that may or may not have bodies.

## three.physics.setVelocity(object, [x, y, z])

Assign a body's speed, in world units per second. This is what a character uses: set it every frame from the
keys that are down, because what you want is a speed.

Only a dynamic body can be given one — a static body's inverse mass is zero so nothing would happen, and a
kinematic body is driven by the transform your script writes so it would be discarded a fraction of a step
later. Both throw and say which.

The solver recomputes the velocity from what actually happened at the end of every step, so this survives one
integration by design.

## three.physics.setAngularVelocity(object, [x, y, z])

Radians per second about each world axis; the vector's length is the rate. Same dynamic-only rule as
`setVelocity`.

## three.physics.applyImpulse(object, [x, y, z], at)

A push, in mass times velocity — so the same impulse moves a heavy thing less, and this is what a jump, a bat
or an explosion wants rather than `setVelocity`. It adds to whatever the body was already doing.

`at` is optional and is an offset from the body's centre in world axes, not a world position: give one and the
push tumbles the body as well as shoving it.

A sleeping body is woken first, so a settled crate and a rolling one answer the same push the same way.

## three.physics.applyTorqueImpulse(object, [x, y, z])

A spin with no shove, so "make this rotate" does not mean solving for an offset and a force that happen to
produce the spin you wanted.

## three.physics.joint(a, b, options)

Bolt two body-backed objects together, and answer with the joint's id — which is what `removeJoint` takes,
because a joint is not a node and has nothing else to be named by.

A joint is a list of limits: some of the joint frame's axes, held to some range. That is glTF's description of
one (KHR_physics_rigid_bodies) and it is what the solver stores, so a limit read out of a `.glb` and a limit
written by hand are the same object.

```js
{ limits: [{ linearAxes: [0,1,2], angularAxes: [0,1,2], min, max, stiffness, damping }],
  axis: [x, y, z], pivot: [x, y, z], stiffness, damping, collide }
```

- Axis 0 is `axis` (default `[0, 1, 0]`); axes 1 and 2 are derived perpendicular to it, so a limit naming
  `[1, 2]` means "the plane the axle is normal to" whichever way the axle points.
- No range is a lock. A limit with no `min` and `max` holds its axes at zero, which is glTF's default for both
  and the opposite of what "no limit" sounds like. A hinge is therefore
  `limits: [{ linearAxes: [0,1,2] }, { angularAxes: [1,2] }]` — everything held but the axle.
- A mask of several axes becomes one limit per axis, which agrees with the file format exactly for a lock and
  differs for a range: a box rather than glTF's cone.
- The joint is made where the bodies are — the pivot defaults to halfway between the two centres and the
  relative orientation is whatever they are turned to right now — so place both objects and then join them.
- `stiffness` is a spring constant and 0 is the rigid end: the solver reads it as `(1 / stiffness) / dt²` and
  special-cases 0 to no give, so bigger is stiffer and something felt on a one-kilogram prop is in the low
  thousands. `damping` is carried into the joint and is not read by the solver yet; it is accepted so a limit
  out of a file survives.
- At least one end has to be dynamic. `collide` is false by default, because two things bolted together
  usually overlap where they are bolted.
- A linear axis is a world direction and does not turn with the bodies, so a slider on something that rotates
  is not expressible; angular axes do turn with them.

## three.physics.joint (the four shorthand types)

`type` names one of four limit lists, expanded in the prelude, so anything it can say can also be said by hand.

- `'fixed'` welds — every linear and angular axis held. The default.
- `'point'` is a ball and socket — the three linear axes held and nothing else.
- `'hinge'` turns about axis 0 — linear held, angular `[1, 2]` held.
- `'slider'` runs along axis 0 — linear `[1, 2]` held, angular all held.

`range: [min, max]` bounds the one free axis a hinge or a slider has. It is refused on `fixed` and `point`,
which have none, and `[0, 0]` is refused because it would lock that axis and weld the joint shut rather than
bound it.

Give `limits` instead and `type` and `range` are ignored — the list is the joint.

## three.physics.removeJoint(id)

Let one joint go, by the id `joint()` answered with. False when the id names nothing, so removing twice is not
an error.

Removing either body removes the joints holding it, so a script that destroys things does not have to track
their joints as well.

## three.physics.soft(object, options)

Simulate this object's own vertices as particles held together by the mesh's edges, and answer with the object.
`{ mass: 1, softness: 0, damping: 0.99, volume: false, bending: false, friction: 0.5, restitution: 0.2 }`.

There is no `shape`: a soft body has no collider, because the thing that collides is the drawing. How it
deforms is decided by how the mesh was modelled, and a denser mesh is a more expensive and more detailed one.

- `softness` is XPBD compliance on the links; 0 cannot stretch.
- `volume` holds the enclosed volume, which is a balloon rather than a bag.
- `bending` resists folding, which is what stops cloth creasing flat. Each takes true or a compliance number.

Two things follow that a rigid body does not have. Its transform is the solver's — `object.position` reads
where the particles average out to and writing it throws, so a script pushes one with `pin()` and nothing else.
And it costs a draw call of its own: two copies of one BoxGeometry are one draw, but two soft ones are two,
because each is writing its own vertices.

It is refused on a skinned mesh, whose vertices already belong to its skeleton.

## three.physics.removeSoft(object)

Take the soft body away, and answer whether there was one. The mesh goes back to the shape it was modelled as,
where the last step left it, and the transform is yours again.

## three.physics.points(object, into) / softCount(object)

The particles, in world space, as a Float32Array of `count * 3` — and how many there are.

One particle per distinct point in the mesh, not one per vertex: a BoxGeometry has twenty-four vertices and
eight particles, because a box that shades with hard edges stores each corner three times and the solver has to
treat those as one or the box falls into six loose squares.

This is how a script finds the index to pin — read them and pick by position, since a particle has no other
name. `into` is optional and lets you reuse one array across frames, the way `texture.read` does.

## three.physics.pin(object, particle, at) / unpin(object, particle, mass)

Hold one particle at a world point — or where it already is, with no third argument — and let it go again.

This is the only way to push a soft body: it has no velocity to set and no centre to shove. A pin is absolute
and is reapplied after every substep, so a pin moved each frame carries the body with it, which is how a soft
thing is dragged, thrown or attached to a hand.

`unpin`'s `mass` is what the particle weighs afterwards, and defaults to the body's own per-particle share.

## object.body

What kind of body `three.physics.add` would give this object, and what it gave it:
`{ shape, mass, friction, restitution, kind }`. Set it yourself to describe one, or read it back after `add` to
see the defaults filled in. Null once the body is removed.

## three.onTrigger(fn)

Call `fn({ type: 'enter' | 'exit', trigger, other })` when a trigger body starts or stops overlapping something,
from inside the frame. `trigger` and `other` are the objects, or null for one whose node has already gone.

One handler; binding again replaces, null unbinds. Synchronous only, and stopped for good if it throws — the
same rules `onClick` follows.

## three.onContact(fn)

Call `fn({ type: 'start' | 'end', a, b, normal, point })` when two bodies touch or come apart. Unlike a trigger,
a contact also produced a physical response.

`normal` and `point` describe the touch and mean something only on a start — by the end there is no contact left
to describe. Same registration and same rules as `onTrigger`.

# The camera

## three.camera.attach(object, options)

Follow an object with the camera.

- `{ offset: [x, y, z] }` is added to its world position and becomes the orbit point every frame.
- `{ distance }` is how far behind the eye sits; 0 puts the eye on the point, which is first person.
- `{ lag }` is seconds of catch-up — 0 for rigid, ~0.12 for a camera that trails.

The follow runs last in the frame, after the animation, the solver and your callback, so the camera is never a
frame behind what it is watching.

It owns the orbit point and nothing else: a drag still orbits, the wheel still zooms, `orbit()` still aims, and
a pan stops working because a pan writes the orbit point. The offset is world space, so a camera bolted into
something that rolls is not expressible. `frameAll()` throws while attached rather than being undone a frame
later.

## three.camera.detach() / three.camera.attached

`detach()` stops following and answers whether it was, leaving the camera exactly where the last frame put it.

`attached` is the object being followed, or null — and null is also how you find out that what you were
following was destroyed, because the host drops the attachment silently rather than throwing from inside a
frame nobody called.

## three.camera.orbit(yaw, pitch, distance)

Degrees, degrees, world units. Any argument may be omitted to leave it alone.

## three.camera.lookAt(x, y, z)

Point the turntable at a world position.

## three.camera.frameAll()

Aim at everything in the scene and back off far enough to see it.

## three.camera.position()

The camera eye, in world space — the point a boom of `distance` puts it. Not `target` (what it orbits) and not
writable.

This is the fix for "which way is the camera looking": you cannot read it from the camera itself otherwise,
because `camera.position` and `getWorldPosition()` do not exist.

The convention: yaw is degrees about +Y from +Z, so `orbit(0,0)` puts the camera at +Z looking toward -Z and
`orbit(90,0)` at +X looking toward -X.

## three.camera.forward()

Where the camera looks, as a unit Vector3 in world space, pitch included.

Compute the camera-relative move frame as `forward()` and `right()` rather than by hand — the signs are easy to
get wrong and read back as the character walking sideways.

## three.camera.right()

The camera's right on the ground plane, unit Vector3, y=0 — the "D" key. Flattened so it stays a strafe
direction while the camera is pitched down at a character.

## three.camera.planarMove(fwd, strafe)

The world-space direction for a camera-relative input: `fwd` is the W/S axis (+1 to -1), `strafe` the D/A axis
(+1 to -1). Returns a unit Vector3 (y=0), or the zero vector for 0,0.

One call that keeps a character glued to the camera's forward line instead of drifting sideways:

```js
const v = three.camera.planarMove(fwd, strafe);
player.position.x += v.x * speed * dt;
player.position.z += v.z * speed * dt;
```

## three.camera.ray(x, y)

The world-space ray through a pixel of the rendered image, as `{ origin, direction }` — two Vector3s with the
direction unit length, which is exactly what `scene.raycast(origin, direction)` takes.

This is the question `scene.pick(x, y)` cannot be asked. A pick needs something already under the cursor, so
dragging a piece across bare ground and dropping one where nothing is yet — the two things an editor does most
— have nothing to pick. Both are this ray met with a plane you chose:

```js
const r = three.camera.ray(x, y);
const t = -r.origin.y / r.direction.y;                  // where it crosses y = 0
const on = r.origin.clone().addScaledVector(r.direction, t);
piece.position.copy(on);
```

`x` and `y` are the rendered image's pixels from its top-left corner — the same ones `scene.pick(x, y)` takes,
`three.input.pointer` answers in and `three.renderSize()` counts, so one cursor position feeds both without
conversion. The ray goes through the pixel's centre, which is where the rasterizer decided its colour.

It is the same ray a pick casts rather than a second derivation from `position()`, `forward()` and `fov`, so a
`raycast` on it finds what `pick` finds at that pixel, at the same `distance`. The origin is therefore on the
near plane and not at the eye: what sits in front of the near plane is invisible, and a ray taken from the
picture does not hit it either.

## three.camera.near / three.camera.far

Where the depth range starts and ends, in world units. Read-only: both are derived, from the orbit distance and
from the scene's own bounds, every time the camera moves.

They are worth reading when something has stopped being drawn — geometry beyond `far` is not dim, it is absent,
and it is culled as well as clipped, so `stats().culledLastFrame` moves too.

# Lights

## three.light.direction / three.light.color / three.light.intensity

The sun — light zero, and the only one that casts a shadow.

`direction` is a world-space surface-to-light vector — the way a face has to point to be fully lit — and is a
live Vector3, so `three.light.direction.y = -1` writes through. It is not normalized, so it reads back as you
wrote it, and a zero one throws rather than making every shaded pixel a NaN.

`color` takes a hex, a triple or an `{r,g,b}` and answers with the triple; `intensity` multiplies it and is how
a light goes brighter than white. Defaults to `[0.35, 0.8, 0.45]`, white, and 1.

## three.light.ambient

The floor a face turned right away from every light gets, 0 to 1: at 0 it is black, at 1 there is no shading at
all and everything is its own flat colour. On `three.light` rather than on each light because it is not a light.
Defaults to 0.25.

## three.light.set(direction, ambient)

The sun and the floor at once. `ambient` may be omitted to leave it alone, and it is the floor rather than a
colour — `three.light.color` is how the sun is coloured. There are up to four lights; `three.lights` is the list.

## three.lights

The list of lights, four slots, the sun in the first — `three.lights[0] === three.light`. `length` is how many
are lit and `max` is how many there can be.

`add(direction, color, intensity)` fills the next slot and answers with it, and also takes
`add({ direction, color, intensity })`; it throws once four are lit rather than dropping the fifth.

`remove(i)` or `remove(light)` takes one out and closes the gap, exactly as `Array.splice` does, so an index
held across a remove names a different light. Light zero cannot be removed — it is the one the shadow map is
fitted around — so turn it off with `three.light.intensity = 0`.

It is iterable: `for (const l of three.lights)`. Only light zero casts; the rest light and do not shadow.

## three.light.shadow

The shadow this light casts, off until you ask. `three.light.shadow = true` turns it on;
`three.light.shadow = { enabled: true, size: 4096 }` sets several at once; and the five properties read and
write one at a time.

- `enabled` — whether the pass runs.
- `size` — texels per side, clamped to 256..8192 and rounded down to a power of two, so it reads back as what
  will be allocated rather than as what you typed.
- `bias` — an extra depth offset in the light's clip space, 0 by default, because each sample is already lifted
  two texels along its own normal. Reach for it in small numbers like 0.0005 if a scene still shows stripes.
- `intensity` — how dark, 0 to 1. 1 takes the whole directional term away and leaves `three.light.ambient`, so a
  shadow is never black unless the ambient floor is.
- `distance` — how far down the view direction the map is fitted, in world units. 0 (the default) means five
  times the camera's own orbit distance, derived every frame.

`distance` is the sharpness knob and it beats `size`: the map covers a square this wide, so halving it is worth
quadrupling `size` and costs nothing. Try roughly the distance shadows are worth having, and watch for the line
across the ground where they stop.

`three.light.shadow.fit` reads back where the map actually landed: `{ live, center, extent, near, far, texel }`,
in world units, for the last frame. Read `extent` first — `extent / size` is the world size of a texel, and that
is what decides whether an edge reads as a shadow or as a staircase. `live: false` means no pass ran.

Nothing is allocated and no shader compiled until the first frame with it on; turning it off costs nothing and
keeps the map for next time; and activating a scene — which `new three.Scene()` does — turns it off.

Everything opaque casts and everything shaded receives: there is no `castShadow` or `receiveShadow`, because two
copies of one mesh disagreeing about it would be two draw calls. Glass casts nothing and neither do debug
helpers.

There is one map, fitted around the whole scene every frame, so blocky shadows mean a large scene rather than a
small map. While the pass is on the camera frustum stops culling, because a caster you cannot see still throws a
shadow into the frame — so `stats().culledLastFrame` reads 0 and `stats().shadowDraws` is what the pass cost.

The way to make that pass cheap is `object.static = true` on whatever will not move again: static casters go into
the map once and are kept, and each frame after draws only the movers. It costs no draw call in the colour pass.
See the static-casters topic.

# Materials

## material.repeat / material.offset

How the map is laid across a surface. `repeat` is `[u, v]` — or one number for both — and is how many times the
image is tiled; `offset` is `[u, v]` in whole repeats, for shifting it.

Without this a surface maps its texture exactly once, so texel density is a function of how big the mesh is and
a 128px image across 100 units is a smear.

On the material, not on the texture as in Three.js: textures here are deduplicated by content across every file,
so a transform on the texture would change every unrelated surface that used the same picture. Two densities of
one image is two materials, which is what they already had to be.

A repeat of zero throws — it maps the whole surface onto one texel.

## mapped_normal(s, texel) — normal maps in a ShaderMaterial

A tangent-space normal map applied to a surface that carries no tangents. In a fragment body:

```slang
float3 n = mapped_normal(s, bumps.Sample(s.uv).rgb);
return standard(s, s.albedo, n);
```

`bumps` is one of the material's declared textures, and `texel` is the map's rgb exactly as sampled — the decode
from [0,1] to a direction happens inside, which is why the map has to be loaded with
`{ colorSpace: three.LinearSRGBColorSpace }`.

No mesh here has a TANGENT stream and there is nowhere to put one, so the frame is rebuilt per pixel from
screen-space derivatives of the world position and the uv. That is what makes it work on any textured mesh,
including a generated PlaneGeometry, and it is also its two limits: a mirrored uv island comes out mirrored
rather than flipped, and a face with degenerate uvs gets the interpolated normal back unchanged.

Fragment stage only — calling it from a vertex body is a compile error, because there are no derivatives there.

A roughness map has no equivalent yet: a roughness or metalness map loads correctly and in the right colourspace,
but there is nothing built in to feed it — a body is free to use one for whatever it likes.

## new three.MeshLambertMaterial({ map, side })

The built-in shader with an image. Compiles nothing, needs no Slang, and cannot fail with a shader diagnostic —
this is the way to put a picture on a shape. With no map it is a side and nothing else, which is the cheapest
skydome.

## material.map

The base colour image, or null. The material's map wins over whatever texture the mesh itself carries, so a
glTF's own image can be overridden and cannot silently override yours.

A mesh with no uvs shows nothing: every parametric shape and every glTF mesh has them, a ConvexGeometry does not
— on one of those the map is set, correct, and invisible.

## new three.ShaderMaterial({ fragment, uniforms })

Compile a fragment function into a material. Uniforms are at most 68 bytes in total (17 floats); each is a
number or an array of up to four numbers.

## mesh.material

Assign a MeshLambertMaterial or a ShaderMaterial, or null for the default shader. Meshes sharing a mesh ref and
a material are one draw call; giving two of them different materials makes two.

## material.dispose()

Give back the reference this handle holds, and with it the pipeline the material was compiled into.

Not a free: the material goes when no mesh names it either, so disposing while a mesh still draws with it leaves
that mesh correct and collects the material when the mesh goes.

Call it on a ShaderMaterial you are done with — an agent iterating on a shader compiles a new pipeline every run,
and without this they accumulate for the life of the process. Disposing twice does nothing; using a disposed
material throws. The default and line materials are shared and cannot be disposed.

`stats().materials` is how you watch it work, and the host prints a line naming the count once it passes 64.

## material.uniforms.<name>

Read or write a uniform. Writing takes effect on the next render.

Only names declared at construction exist; assigning to any other name throws. A uniform declared as a table is
written a row at a time — `material.uniforms.palette[1] = [0, 1, 0]` — or all at once.

## mesh.color

This copy's own tint, multiplied into albedo. `[r, g, b]`, `[r, g, b, a]`, `{r, g, b}` or a hex number like
`0xff8800`.

Costs no draw call: copies of one mesh may all differ. Works with no material at all, and reaches a `shade()`
body as `s.color` with albedo already tinted.

The fourth channel fades this copy when — and only when — its material was built transparent: it multiplies the
material's own opacity, so one of a thousand copies sharing a draw call can be half there while the rest are
solid. On an opaque material the alpha is discarded by the pipeline and changes nothing.

## mesh.variant

Which row of the material's uniform table this copy draws with, as `s.variant` in the body. Costs no draw call
either.

Zero and meaningless until the material declares a table; past the end it is clamped to the last row rather than
reading rubbish.

## three.NoBlending / three.NormalBlending / three.AdditiveBlending

The values `material.blending` takes — 0, 1 and 2, Three.js's numbers again.

`NormalBlending` is what `{ transparent: true }` means and is what glass, water and a foliage card want.
`AdditiveBlending` never darkens what is behind it and is what fire, a glow and a beam want.

Both are decided when the material is constructed and neither can be assigned afterwards: this device bakes
blending into the pipeline, so changing it is building another material, which is one line.

Three things follow, worth knowing before a scene is built on them:

- Transparent draws are sorted farthest-first against the near plane and drawn after every opaque one, so glass
  shows the wall behind it.
- Copies inside one instanced bucket are not sorted against each other — they are one draw call, and the depth
  order within it is whatever the vertex order is. Three.js's per-object sort has the same limit, and the fix in
  both is to space the panes out or split them.
- A transparent frame may issue more draw calls than `stats().drawCalls` reports, deliberately: depth
  interleaving splits buckets and the split depends on where the camera is, so `stats()` answers what the scene
  costs rather than what this angle cost. The number is a floor, never an over-estimate.

## three.FrontSide / three.BackSide / three.DoubleSide

The values `material.side` takes — 0, 1 and 2, the same numbers Three.js gives them.

`BackSide` keeps the back faces, which is what makes a sphere visible from inside: it is how a skydome is built,
and scaling one by -1 instead does nothing, because a negative scale does not reverse a triangle's winding.

`DoubleSide` keeps both and is what a plane seen from either direction wants — a flag, a leaf card, a piece of a
wall you can walk past.

# Textures

## texture.read(into)

The pixels, copied back off the device: a Uint8Array of `width * height * 4` RGBA bytes.

The bytes that went in, not the ones the shader sees — the copy converts nothing, so a DataTexture reads back
byte-for-byte identical to the array it was built from and a PNG reads back as its own pixels; the sRGB decode
happens at sample time and is not in here.

`into` is optional and lets you reuse a buffer. This copies off the device and waits for the queue, so it belongs
at load or in a test rather than in a frame. It is also what makes a texture testable and what lets
`scene.export` write a generated one.

## three.texture(path, options)

Decode a PNG, JPEG or KTX2 and upload it, answering with a Texture. Synchronous.

A KTX2 may hold Basis (ETC1S or UASTC, which is what KHR_texture_basisu means) or an ordinary Vulkan format,
compressed or not; either way it arrives as RGBA8, and a `.glb` whose textures are KTX2 loads with them. The
format comes from the file's first bytes rather than its name.

Deduplicated by the decoded image, so the same picture reached by two paths — or by a path and a `.glb` — is one
upload, and `three.stats().textures` counts it once.

`options` is `{ colorSpace, generateMipmaps, filter }` and nothing else; an unknown key throws rather than being
ignored, so a Three.js line carrying `magFilter` or `wrapS` is told so instead of quietly doing something different.

## three.SRGBColorSpace / three.LinearSRGBColorSpace / three.NoColorSpace

Which space a texture's bytes are in, passed as `three.texture(path, { colorSpace })`. This is the difference
between a colour map and a normal map.

- `SRGBColorSpace` is the default and is right for anything an artist looked at while making it — a base colour,
  an albedo, a photograph.
- `LinearSRGBColorSpace` is for a map whose channels are numbers rather than colours: a normal map's xyz, a
  roughness or metalness or occlusion map, a height field, a lookup table.
- `NoColorSpace` is Three.js's other spelling of linear and is the same image here.

Neither mistake reports an error: a colour map loaded linear is washed out and reads as a lighting bug, and a
normal map loaded sRGB goes soft and reads as a bad bake.

The colourspace is part of a texture's identity, so the same file loaded both ways is two uploads on purpose.

## three.LinearFilter / three.NearestFilter

Which sampler a texture is read through, passed as `three.texture(path, { filter })` or
`new three.DataTexture(data, w, h, { filter })`. It is one knob, decided at upload.

- `LinearFilter` is the default and is right for a picture of something: it blends neighbouring texels, which
  is what a photograph wants and what stops a textured floor shimmering.
- `NearestFilter` reads each texel as a square, which is what pixel art, a sprite sheet and a shader-indexed
  table want. One bright texel in a lookup table magnified under linear is a soft square the size of everything
  beside it — the symptom this exists to prevent.

Like the colourspace it is part of a texture's identity: the same pixels asked for both ways are two uploads,
because sharing a slot would hand whichever caller came second the other one's sampler.

## new three.DataTexture(data, width, height, options)

Upload pixels a script generated. Rows run bottom-to-top, four bytes per pixel.

The bytes are read and copied inside the call, so the array is yours again immediately. Wrong byte counts are
refused with the arithmetic in the message rather than uploaded skewed.

`options` is `three.texture`'s; a generated lookup table wants
`{ colorSpace: three.LinearSRGBColorSpace, generateMipmaps: false, filter: three.NearestFilter }` — the mips
off so the table is not blurred, the filter nearest so one texel is one texel.

## texture.levels and texture.generateMipmaps

How many mip levels the image got, and whether that is more than one.

A full chain is built by default, which is what stops a textured floor shimmering as the camera moves — without
one, every sample comes from the full-resolution image however few pixels the surface covers.

Both are read back off the upload rather than echoed from what you asked for, so a device that cannot filter the
format reports false here having been passed true. Pass `{ generateMipmaps: false }` for pixels meant to be
indexed exactly rather than sampled at a distance.

## texture.dispose()

Give back the reference this handle holds. Not a free: the image goes only when nothing names it, so disposing
while a material still draws with it leaves that material correct. Disposing twice does nothing; using a disposed
texture throws.

# Post-processing

## three.setPost({ fragment, uniforms, textures })

Run one shader over the whole finished frame. `fragment` is a Slang function `float3 post(Post p)` returning
linear rgb.

`Post` carries:

- `color` — this pixel of what ran before this pass, already decoded to linear. The rendered scene, for the first
  pass of a chain.
- `scene` — this pixel of the rendered scene whatever has run since; equal to `color` on the first pass.
- `uv` — 0..1 across the frame, (0,0) top left.
- `resolution` — the frame in pixels. `1.0 / p.resolution` is one texel, which is what a blur steps by.
- `time` — seconds since this shader was set, on the game clock, so a paused world has a still chain.
- `depth` — how far this pixel is from the camera, in world units along the view direction. Already linearized,
  which is the point of it: the raw device depth spends half its range on the first few percent of the frustum,
  so fog, depth of field and distance-aware edges written against it bunch up against the camera. A pixel nothing
  was drawn into reads as the far plane.
- `tap` — another pass's output, which only `three.addPass` can fill. See its `reads`.

There are no normals and no motion vectors.

`p` gives you this pixel; the two images behind `color` and `scene` are also in scope as samplers named `prev`
and `scene`, so a body that needs the neighbours reads `prev.Sample(p.uv + off)` — which is what the texel step
is for, and the whole of how a blur is written.

Each uniform is readable in the body by its own name. They are at most 104 bytes in total (26 floats), each a
number or an array of up to four numbers, and not a table — a post pass draws one triangle over the whole frame,
so there are no instances for a row to belong to.

`textures` is a ShaderMaterial's: `{ grade_lut: tex }` declares a Sampler2D the body reads by that name, up to
four, with no binding number written anywhere. They are what a frame cannot supply about itself — a ramp to grade
through with `grade_lut.Sample(float2(p.color.r, 0.5))`, a noise field to distort or dither by, a mask that says
where the effect applies. Tile one by the frame rather than by uv, `p.uv * p.resolution / 256`, or it stretches
with the window. A sampler you leave null reads white.

It compiles on the call, so a bad body throws here carrying the Slang diagnostic with `post:<line>` counting the
lines you wrote; a failed set leaves the previous chain running, so it is the old shaders or the new one and
never neither. Needs a GPU device.

It applies identically to the window, to `three.render()` and to every screenshot — there is one recording path
and the branch is inside it. `post()` returns rgb and never alpha: a screenshot forces alpha opaque anyway, so a
body that could dim it would make the window and the file disagree.

`setPost` replaces the whole chain (the old pipelines are retired for you) and `three.addPass` adds to it. The
chain belongs to the renderer rather than to the scene, so it survives `new three.Scene()` and outlives the
script that set it. `three.setPost(null)` is the only thing that clears it.

## three.addPass({ fragment, uniforms, textures, reads })

Put another full-screen pass at the end of the chain. The same spec `three.setPost` takes and the same handle
back; the difference is what the body reads.

`p.color` is what the pass before this one wrote, and `p.scene` is the frame as the geometry left it. Those two
are the dependency model, and between them they cover most of what a multi-pass effect wants: bloom is
`blur(bright(scene)) + scene`, which is `p.scene` three passes later.

`reads` is the third source, for what they do not cover: hand it the handle an earlier `addPass` gave you and
that pass's output arrives as `p.tap`.

```js
const bright = three.addPass({ fragment: threshold });
three.addPass({ fragment: combine, reads: bright });
```

That is the pass in the middle of a chain that two later passes both want, or a mask one pass built for another
to apply. The sampler is in scope as `tap_image` (not `tap`, which is a word bodies use) for reading a different
pixel of it.

It costs the tapped pass an image of its own — the chain ping-pongs two between passes and a tapped one cannot be
overwritten — so it is one allocation per distinct pass tapped and nothing for a chain that taps none.

`reads` must name a pass already in the chain; a later index or a cycle throws. It belongs on `addPass`, never on
`setPost`, which is always the first pass and has nothing before it. Leave it out and `p.tap` is the rendered
scene, the same as `p.scene`.

Everything between passes is linear float rather than 8-bit, so a pass may return values above 1 and the next one
still sees them; the display encode happens once, after the last pass.

Adding to an empty chain is exactly a `setPost`. It does not invalidate handles you already hold — earlier passes
keep their index and their shader — which is what lets a script animate every pass at once. There is no
`removePass`: dropping one out of the middle would renumber the handles after it, and a `setPost` followed by the
`addPass` calls you want is the same effect said in a way that cannot leave a handle pointing at somebody else's
shader.

## the handle three.setPost() and three.addPass() answer with

`{ fragment, index, uniforms, textures }` — the body that is running, where in the chain it runs, and live
uniforms and textures objects exactly like a material's.

`post.uniforms.gain = 2` is a 4-byte write that takes effect on the next frame with no compile and no pipeline,
which is what makes an animated post pass free, and `post.textures.grade_lut = other` swaps an image the same way.

Only names given at the call exist; assigning any other throws. A later `setPost` replaces the whole chain, and
writing through a handle from before it throws rather than steering whatever is at that index now. `addPass`
leaves earlier handles working.

# The interface and debug output

## three.debug.write(...values)

How a script answers with a value. Every argument becomes one entry in the `debug` array of the result, as JSON
rather than as text inside the log — so an object stays an object instead of arriving escaped in a string.

It can be called from wherever the number was worked out rather than gathered into one expression at the last
line, and it works inside a system or an animation callback. On the command line it prints as `debug: [...]`.

Entries written in a frame are held and reported by the next run, the way `console.log` from a callback is. A
value with no JSON form — a cycle, a function, undefined — arrives as the text `String(value)` would have shown
rather than punching a hole in the array.

```js
three.debug.write({ crates: Crate.count, wumpa: Wumpa.count });
```

## three.debug.overlay(text)

One line over the top-left of the frame, and one entry in the run's `debug` array as `{ overlay: "..." }` — so a
person and an agent read the same line, and a screenshot carries it, because the text is drawn into the offscreen
target the same as the scene is.

It lasts one frame: set it again each frame to keep it up, which makes a HUD one line and lets a
one-shot note clear itself.

```js
three.frame(() => three.debug.overlay(`hp ${p.hp}`));
```

Text only, no layout and no widgets, so nothing here can swallow a click.

## three.ui.set(tree)

The interface, as one description: a tree of plain objects, each with a `type`.

- Layout — `column`, `row`, `stack`, `padding`, `grid`, `clip`, `anchored`, `scroll`.
- Painted — `rect`, `label`, `draw`.
- Interactive — `button`, `checkbox`, `slider`, `select`, `tree`, `textfield`, `menu`, `dialog`, `confirmDialog`,
  `fileBrowser`.

Children go in `children: [...]` or `child: {...}`, and a falsy child is skipped, so `cond && {...}` is how a row
is conditional.

Colours take a hex number, an `[r, g, b]` or an `[r, g, b, a]`; `radius` and insets take one number, two, or four
in cui's order — insets `{left, top, right, bottom}` and radius `{TL, TR, BR, BL}`. `size` is per axis and 0 means
take what you are offered.

Handlers are `onClick`, `onChange`, `onCommit`, `onSubmit`, `onSelect`, `onToggle`, `onHover`, `onConfirm`,
`onDismiss`, `onChoose` and `onPointer`, and they must be synchronous, because a handler runs inside the frame and
the frame does not wait.

It is drawn over the finished frame into the same image a screenshot reads, so an agent sees the interface a
person sees. `three.ui.set(null)` takes it down.

Call this when the shape changed and `three.ui.patch` when a value did: the tree is retained and a node that did
not change costs nothing to redraw, so rebuilding it every frame is the one thing worth not doing.

The other door is `three.Widget`, which does that bookkeeping for you: `render()` describes the interface as it is
now and what reaches the host is the difference. The two are exclusive — this verb throws while a widget is
mounted — because the last one through would win every frame.

## menu

A menu bar: one or more top-level titles, each opening a dropdown when clicked.

- `menus` — `[{ title, items }]` (`title` also takes `label`). Default `[]`.
  - An item is a string (its label), `'-'` or nothing (a divider), or `{ label, shortcut, checked, disabled }`.

`onSelect(menu, item)` fires when an entry is picked — the index of the title on the bar, then the index of the
entry beneath it, both from zero. `item` counts every row of the dropdown in order, dividers included, because
that is the order cui built them in.

`three.ui.patch` can replace `menus` wholesale; nothing else about a menu is a value.

```js
three.ui.set({
  type: 'menu',
  key: 'mainMenu',
  menus: [
    { title: 'File', items: [
      'New', 'Open…', '-',
      { label: 'Save As…', shortcut: 'Ctrl+Shift+S' },
      { label: 'Quit', shortcut: 'Ctrl+Q' },
    ] },
  ],
  onSelect: (menu, item) => { if (menu === 0 && item === 3) saveAs(); },
});
```

## confirmDialog

A yes/no question the interface owns: a title, a message and two buttons.

- `message` (or `text`) — the question. Read after the general caption, so `message` wins if both are given.
- `title` — defaults to `''`.
- `confirm` — the confirm button's label. Empty is `'OK'`.
- `decline` — the decline button's label. Empty is `'Cancel'`.
- `open` — rides on `checked`: whether the question is showing. Default `false`.

`onConfirm()` fires for the confirm button, with no arguments. `onDismiss()` fires for every other way out — the
decline button, the close glyph, ESC — also with no arguments, because to a script "no" and "went away" are the
same event.

`open` is the value a snapshot must name: a `three.ui.set` that leaves it out is a question that defaults closed,
which is why a HUD toggles it with `three.ui.patch(key, { open })` instead of rebuilding. `text` (the message) is
patchable too, and can be changed while the question is still open.

```js
three.ui.set({
  type: 'confirmDialog', key: 'deleteConfirm', title: 'Delete file',
  message: `Delete ${name}? This cannot be undone.`,
  confirm: 'Delete', decline: 'Keep', open: confirming,
  onConfirm: () => { del(name); confirming = false; },
  onDismiss: () => { confirming = false; },
});
```

## fileBrowser

A directory listing a script can pick a file out of.

- `start` (or `path`) — where it opens. Defaults to the root it is confined to.
- `mask` — rides on `options`: a list of `path::ls`-style patterns (literal text with at most one `*`, e.g.
  `'*.glb'`), any one of which a file must match to be listed. Directories are never filtered. Empty (the default)
  shows everything.

It can only look inside the assets directory a `--assets` boot was given — the same confinement `three.load` and
`three.inventory` use — so a bad start opens at that root instead of failing, and `'../..'` cannot walk out of it.
A process with no assets directory (`--mcp`, or the bare CLI) is not confined at all. The paths it hands back are
relative to that root, which is exactly the path form `three.load` accepts.

`onChoose(path)` fires when a row is activated (double-click, Enter) — the string path. `onSelect(path)` fires for
a single click, highlighting a row without opening it. `onChange(path)` fires when the listing itself moves to a
new directory, which is what a breadcrumb reads.

`three.ui.patch` can replace `options` (the mask) wholesale — it re-reads the current directory under the new
filter. `start` is not patchable; open somewhere else with `three.ui.set`.

```js
three.ui.set({
  type: 'fileBrowser', key: 'kitPicker',
  start: 'kit/', mask: ['*.glb'],
  onChoose: path => three.load(path),
});
```

## dialog

A floating titled panel holding whatever tree you like — the one interactive kind whose body survives being
closed.

- `title` (or `text` or `label`) — defaults to `''`.
- `open` — rides on `checked`: whether the panel is showing. Default `false`.
- `modal` — dims and blocks the rest of the interface while open.
- `closeOutside` — a press on that dim also dismisses.
- `scrim` — the dim's colour. Rides on `pressColor`, since a dialog has no pressed state of its own to spend that
  field on.
- `children` / `child` — the body. Layout fields (`gap`, `size`, `main`, `cross`, …) describe this body, not the
  panel chrome, which cui sizes itself.

`onDismiss()` fires with no arguments for the close glyph, ESC, or a press on a close-outside backdrop. It does
**not** fire for a script's own `three.ui.patch(key, { open: false })` — a script that just closed its own panel
does not need telling.

Closing does not rebuild the body: a `dialog`'s children are an element the host keeps and cui borrows rather than
a list rebuilt from the snapshot, so text typed into a field, a scroll offset, a dragged position are exactly where
they were left when it opens again. `open` is the value a snapshot must name, for the reason a confirmation's is.
`three.ui.patch` can change `open` and `text` (the title — renaming it while open costs the keyboard focus anything
in the body was holding, since the panel rebuilds); nothing else here is a value.

**Put a dialog in a `stack`.** cui places the panel against where the node was last drawn, so a node its parent
moves — the second child of a column, say — puts the panel that far wrong and never corrects it. A stack's
children all share one origin, and a modal wants that for a second reason: it fills what it is offered, so in a
column it would claim a row the column's whole height.

```js
three.ui.set({
  type: 'stack',
  children: [
    { type: 'rect', size: [960, 540], color: 0x101010 },
    {
      type: 'dialog', key: 'saveAs', title: 'Save As', open: showSaveAs,
      modal: true, closeOutside: true, size: [320, 0],
      children: [{ type: 'column', gap: 8, children: [
        { type: 'textfield', key: 'saveName', text: name, onChange: t => name = t },
        { type: 'row', gap: 8, children: [
          { type: 'button', text: 'Cancel', onClick: () => showSaveAs = false },
          { type: 'button', text: 'Save', onClick: () => save(name) },
        ] },
      ] }],
      onDismiss: () => { showSaveAs = false; },
    },
  ],
});
```

## three.ui.patch(key, props)

One keyed node, one or more of its values — the verb a HUD uses.

```js
three.frame(() => three.ui.patch('fps', { text: `${fps | 0} fps` }));
```

A node carries a `key` in the snapshot that named it, and the key lives until the next `three.ui.set`. Patching
one that names nothing throws rather than doing nothing, because a HUD that silently froze is the failure that
costs an afternoon.

The fields are the ones that are values rather than structure: `text`, `value`, `checked`, `open`, `selected`,
`offset`, `disabled`, `color`, `min`, `max`, `size`, plus `ops`, `options`, `rows` and `menus`, which replace a list
wholesale. Anything that would change the shape of the tree is a `set`.

## three.ui.draw(ops)

The screen-space layer: a list of drawings positioned in frame pixels. A crosshair, a health bar, a damage flash
and a minimap are all this, and none of them is a widget.

Seven ops, which are the whole drawing surface the built-in widgets paint with:

- `rect` `{at, size, color, radius, borderColor, borderWidth}`
- `circle` `{center, radius, color}`
- `ellipse` `{center, radii}`
- `line` `{from, to, thickness, color}`
- `arc` `{center, radius, start, sweep, thickness, color}` — radians, 0 at +x, turning clockwise
- `text` `{at, text, size, color}`
- `shadow` `{at, size, blur, color, radius}`

Coordinates are the same top-left image pixels `three.input.pointer` arrives in, so a reticle at the cursor needs
no conversion.

It is a `three.ui.set` — one draw node filling the frame — so it replaces the interface. To put drawings beside
widgets, use `{ type: 'draw', size, ops }` inside the tree, where the coordinates are then the node's own and
`onClick` makes it clickable.

## three.ui.measure(text, options)

What a string will take, as `[width, height]` in pixels. `options` is `{ font, size }`.

Drawing text by hand is arithmetic without it — centring a readout inside an arc is a measured width — and this is
the same measurement the renderer makes when it lays the glyphs down, so positioning by it lands where they go.

## three.ui.slot

Where a native plugin has offered to let a script draw, if one has:
`{ present, generation, x, y, width, height }`.

A host loaded with `--plugin` can name an element of its **own** interface as the place a snapshot goes. With one
offered, `three.ui.set` lands in that pane and the application around it stays on screen; without one — no plugin,
or a plugin that has offered nothing — `present` is false and `set` behaves as it always has, taking the frame.

The snapshot does not survive the slot. The pane can be closed or its tab switched, and what was in it is
recycled, so a panel written against an editor watches the generation and draws itself again:

```js
let seen = -1;
three.systems.frame('panel', () => {
  const slot = three.ui.slot;
  if (!slot.present) return;
  if (slot.generation !== seen) { seen = slot.generation; three.ui.set(panel(slot)); }
  three.ui.patch('count', { text: `${n}` });
});
```

`width` and `height` are the pane's, in the same points every other number here is in, and are zero for the one
frame between the plugin offering the slot and the interface laying it out.

`x` and `y` are the pane's top-left corner in window points. They are there for one job: `three.input.pointer` is
the **window's** and knows nothing about panes, so a panel that draws its own controls with `three.ui.draw`
subtracts them to hit-test.

```js
const p = three.input.pointer;
const local = { x: p.x - slot.x, y: p.y - slot.y };
```

Widgets in a snapshot never need this — the interface lays them out and hit-tests them. The pointer reading is
global, so it is true through a menu the host has painted over the pane; a `draw` node does not own the pointer
yet.

## three.ui.scale

How big the whole interface is drawn. 1 is the size every other number in this section is written against, and
1.25 makes everything a quarter bigger.

```js
three.ui.scale = 1.25;
```

It scales the coordinate space rather than a font: the tree is laid out in a space that much smaller and stretched
back over the frame, so the chrome a script cannot put a number on — a menu bar's height, a dialog's title, a file
browser's rows — grows with the panels around it. Glyphs are rasterised at the frame's own density, so text comes
out bigger rather than blurrier.

Reading it answers the scale in force. A value that is not positive throws, and anything outside 0.25 to 4 is
clamped to it.

The one thing it moves: `three.ui.draw` and a `draw` node's coordinates are the interface's, and
`three.input.pointer` is the window's. At a scale other than 1 a drawing placed at the cursor divides.

```js
const p = three.input.pointer, s = three.ui.scale;
three.ui.draw([{ op: 'circle', center: [p.x / s, p.y / s], radius: 8, color: 0xffffff }]);
```

## three.ui.clear()

Takes the interface down, mounted widgets included.

`three.debug.overlay` is not part of it and stays: the debug line and a script's interface are two floors of one
root, with the line always on top.

## three.ui.flush()

Re-render every `three.Widget` whose state has changed, now, instead of when the frame reaches the `ui.widgets`
system.

A script only needs it to look at an interface without drawing a frame first — a test, or a screenshot taken
straight after a mutation.

## three.debug

What the renderer draws instead of the scene, when you ask. `three.debug.view` is `'off'` (the default),
`'shadow'` or `'shadowMap'`.

It exists because a frame with no visible shadows has three explanations — the pass did not run, the pass ran and
the map is fitted somewhere else, or everything in shot is genuinely inside one big shadow — and until this
existed the renderer distinguished none of them.

- `'shadow'` draws how much light reaches each surface as greyscale: white is lit, black is fully shadowed.
  Uniformly white is a pass that did not run or a fit nothing landed in; uniformly dark usually means the sun is
  low enough that a wall is shadowing the whole scene.
- `'shadowMap'` draws the depth the lookup reads at each surface, near-to-far greyscale — the map itself, seen
  through the geometry that samples it. Magenta is outside the fitted box, so a mostly-magenta frame is a
  `three.light.shadow.distance` fitted somewhere other than where you are looking; dark purple is no shadow pass
  this frame.

The sky is not a surface and has no shadow, so a debug view colours only what the geometry covers.

It is deliberately not scene state: `new three.Scene()` does not clear it, for the same reason it does not move
the camera. Pair it with `three.light.shadow.fit` for the numbers, and with `--frames` if you are running
headless.
