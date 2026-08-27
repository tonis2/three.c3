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

## What is in here

    three            the engine, with the Slang shader compiler linked in
    libvulkan_*      the GPU driver (macOS only — see below)
    SKILL.md         the guide
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

**Windows** — nothing to install. `vulkan-1.dll` is a system library that
current GPU drivers put there. If a run reports no device, update your graphics
driver.

## Moving the binary

**macOS** — the driver is found relative to the executable, so move the whole
folder rather than the binary alone. If you want `three` on your `$PATH`,
symlink to it or add this directory; do not copy the executable out on its
own, or it will report no Vulkan device.

**Linux / Windows** — `three` is self-contained and the loader is the system's,
so the executable can be copied anywhere on its own.
