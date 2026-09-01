# three.c3

A Three.js-shaped scene API over direct Vulkan.

Write scenes in JavaScript; they run on a modern Vulkan renderer. Connectable to a coding agent over MCP, which can build,
inspect and debug a scene without you in the loop.

### Features

- **Vulkan renderer** — instancing, shadows, skinning, post-processing, sky
- **glTF** — load a `.glb` or `.gltf`, pull meshes out of a kit and place them
- **Slang shaders** — compiled at startup, so editing a `.slang` and re-running shows it
- **KTX textures** — compressed, transcoded on load
- **Animation** and skeletal skinning, instanced animations
- **Physics** — rigid bodies, joints, heightfields
- **UI** — declared from JavaScript classes
- **MCP server** — the agent tools an assistant drives the engine through

### Example

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

### Running

```sh
./build/three --script examples/village.js   # one script, then keep the window up
./build/three --assets mygame                # boot mygame/main.js as a module
./build/three --screenshot shot.png          # render one frame and exit
./build/three --help                         # every flag
```

Use `--debug` flag for debug info and hot-reload (Shift+R)

There are complete scenes in [`examples/`](examples/) to start from.

### Agents

```sh
./build/three --mcp        # agent tools on 127.0.0.1:8808
```

`.mcp.json` in this repo already points there, so an agent session in a checkout picks it up.
Three tools: `run_script` answers with everything the script logged, the scene's stats and a
PNG of the frame; `screenshot` re-renders it; `get_api_docs` is the API, searchable.

### Building

Needs [c3c](https://github.com/c3lang/c3c) — v0.8.3 is what the releases are built with.

```sh
git clone --recursive https://github.com/tonis2/three.c3.git
cd three.c3
./setup.sh
c3c build 
```

`setup.sh` fetches the Slang compiler and, on macOS arm64, a Vulkan driver. Both are
release assets rather than committed binaries, so a clone stays cheap. It is safe to
re-run, and takes one step by name — `./setup.sh slang`.

For a release build: `c3c build --safe=no -O3`

### Documentation

The API is written in [`docs/`](docs/) — start with
[differences](docs/differences.md), which is where scripts that fail usually fail.

Prebuilt binaries for macOS arm64, Linux x64 and Windows x64 are on the
[releases page](https://github.com/tonis2/three.c3/releases).

Website: _url comes here later_

MIT licensed.
