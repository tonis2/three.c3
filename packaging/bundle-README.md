# three

A single binary that renders a scene described in JavaScript. The API is
Three.js-shaped, but it is not Three.js — `SKILL.md` beside this file is the
guide, and `three.getApiDocs()` inside the engine is the reference.

## Run it

**macOS** — the download is quarantined and the binary is not notarised, so
clear that once:

    xattr -dr com.apple.quarantine .
    ./three --help

**Linux / Windows**

    ./three --help

There is nothing to install, nothing to build and no launcher script. The
shader templates and the shader compiler are both inside the executable, so
`three` runs from whatever directory you are in. On macOS the GPU driver is
the one file that still has to travel with it — see "Moving the binary".

## A first scene

    echo 'const s = new three.Scene();
    const m = new three.Mesh(new three.BoxGeometry(1,1,1));
    m.color = 0xff8800; s.add(m);
    three.camera.frameAll();' > hello.js

    ./three --headless --script hello.js --frames 1 --screenshot hello.png

`--script` and `--assets` keep running after the script returns, so a
non-interactive run needs `--frames` or `--screenshot` to bound it.

## The examples

`examples/` holds five scenes that build everything they draw in code. There
are no models and no textures on disk — the geometry and the images are
arithmetic — so they need no assets folder behind them and run straight out of
this directory:

    ./three --script examples/alley.js       # material.repeat / offset, and the physics verbs
    ./three --script examples/village.js     # a street, a crowd, and nine textures that are arithmetic
    ./three --script examples/tank_yard.js   # a Battle City in four API pieces
    ./three --script examples/vfx.js         # what a material's own samplers are for
    ./three --script examples/wumpa_run.js   # a Crash-shaped run down a jungle hollow

Each file opens with a comment saying what it demonstrates and which keys it
answers to. Add `--mcp` to any of them to attach an agent to the scene while
it runs. Those headers spell the command `./build/three`, which is the path in
a source checkout; from this folder it is `./three`.

## What is in here

    three            the engine, with the Slang shader compiler linked in
    libvulkan_*      the GPU driver (macOS only — see below)
    SKILL.md         the guide
    examples/        five scenes to run — see below
    LICENSE

That is the whole list. Earlier releases also carried `libslang-*.dylib`
beside the binary; the compiler is inside `three` now, so a bundle that still
has those files is an old one.

## Requirements

Nothing is linked against Vulkan: `three` opens the loader with `dlopen` at
startup and the loader finds your GPU's driver itself. What that means per
platform:

**macOS (Apple Silicon), 26 or newer** — nothing to install. The loader and the
driver are both in this folder and are tried before anything on the system. The
version floor is the driver's, not the engine's: KosmicKrisp is built on Metal
4, so macOS 15 and earlier cannot load it at all, and what you see there is
`E_ERROR_INCOMPATIBLE_DRIVER` — the same message as a machine with no Vulkan,
because from the loader's side it is the same situation.

**Linux** — nothing to install on a machine that can already run 3D
applications. `libvulkan.so.1` and your GPU's ICD both come with the graphics
stack (Mesa, or your vendor's driver) and `three` picks them up.

The exception is a machine with no graphics stack at all — a minimal container,
a headless server, some CI images. There `three` will say it could not open a
Vulkan loader, and what is missing is:

    sudo apt install libvulkan1            # the loader itself
    sudo apt install mesa-vulkan-drivers   # lavapipe, if there is no GPU to use

**Windows** — `vulkan-1.dll` is a system library that current GPU drivers put
there, so there is nothing to install for Vulkan itself. If a run reports no
device, update your graphics driver.

One thing may be missing on a bare machine, and it fails before the program
prints anything: `three.exe` imports `VCRUNTIME140.dll`, `VCRUNTIME140_1.dll`
and `MSVCP140.dll`. Those are the Microsoft Visual C++ runtime — the shader
compiler linked into the binary is C++ and is built against the shared CRT —
and they come with almost every application that has ever been installed, so
most machines already have them. A machine that does not exits with
`0xC0000135` and no message at all. The fix is the Microsoft Visual C++
Redistributable for x64, from Microsoft, or:

    winget install Microsoft.VCRedist.2015+.x64

## Where it writes

Nothing lands in the folder you run from.

    compiled shaders   ~/Library/Caches/three.c3          (macOS)
                       %LOCALAPPDATA%\three.c3            (Windows)
                       $XDG_CACHE_HOME or ~/.cache/three.c3
    a game's saves     ~/Library/Application Support/three.c3/<game>
                       %AppData%\three.c3\<game>
                       $XDG_CONFIG_HOME or ~/.config/three.c3/<game>

The first is a cache and is safe to delete: the next run compiles the shaders
again, which costs about three seconds once. `--cache-dir <dir>` moves it and
`--cache-dir ""` turns it off. The second is not a cache — deleting it deletes
somebody's progress — which is why the two are kept apart.

A game says `three.save.path` if you want the exact folder from inside it.

**Shipping a warm cache.** A `shader-cache/` directory beside the executable is
read and never written. The `.slangmod` files in it are keyed on the shader
source and the compiler, not on the machine, so the ones a release was built
with are the ones any machine would compile for itself: copy them in and first
start drops from about 3.5 seconds to 1.6.

## Attaching an agent

`--mcp` works in every build, including this one. `three --mcp` serves the agent
tools on 127.0.0.1:8808 and composes with everything else — `three --assets
./game --mcp` plays the game and answers tool calls against the same scene, in
the same loop. `SKILL.md` beside this file is what to hand the agent.

Nothing outside your machine can reach it: the port is bound on the loopback
address only.

## Moving the binary

**macOS** — the driver is found relative to the executable, so move the whole
folder rather than the binary alone. If you want `three` on your `$PATH`,
symlink to it or add this directory; do not copy the executable out on its
own, or it will report no Vulkan device.

**Linux / Windows** — `three` is self-contained and the loader is the system's,
so the executable can be copied anywhere on its own.
