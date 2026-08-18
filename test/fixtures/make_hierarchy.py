#!/usr/bin/env python3
"""Write test/fixtures/hierarchy.glb — the fixture the node-tree checks assert on.

The other two fixtures both place their geometry by baking coordinates into the
vertex data, with every node at the identity. That is one of the two ways a glTF
can be authored and it is the way that renders correctly through a loader which
throws the node hierarchy away — which three.c3's did, from M1 until G3, with
nothing in the suite able to notice.

This is the other way. Every mesh here is the same quad at the origin, and the
only thing that puts the pieces anywhere is their nodes:

  * `pivot` — no mesh. Translated, and rotated a quarter turn about +Y, so a
    child of it lands somewhere neither translation alone nor rotation alone
    would put it.
  * `arm` — child of `pivot`, scaled 2x, and its mesh has **two primitives**, so
    the "one glTF node becomes a group of meshes" branch is covered.
  * `tip` — child of `arm`, translated +1 along local X. Its world position is
    the whole chain applied in order, and it is wrong under any of: dropped
    hierarchy, dropped scale, wrong rotation order, wrong multiply order.
  * `loose` — a second root, stating its transform as a **matrix** rather than a
    TRS triple. glTF allows either and a loader that reads only TRS leaves this
    one at the origin.

No images and no materials: the textures are `textured.glb`'s job and an
untextured file covers the base-colour-factor path in the same pass.

## The animations

Three clips, each isolating one thing a sampler can get wrong:

  * `slide` — a LINEAR translation on `tip`, from (1,0,0) to (3,0,0) over two
    seconds. The midpoint is (2,0,0), which is a value no key holds, so a
    sampler that snaps to the nearest key fails while one that interpolates
    passes.
  * `spin` — a LINEAR rotation on `arm`, a half turn about +Y in two 90° steps.
    Halfway through the first step the correct answer is a 45° rotation, which
    component-wise mixing of the two quaternions does **not** produce: it gives
    a shorter turn and a non-unit quaternion. This is the check on slerp.
  * `blink` — a STEP scale on `loose`, 1x until t=1 then 3x. A sampler that
    interpolates a STEP channel is halfway between at t=0.5, which is wrong in a
    way that a LINEAR-only implementation renders perfectly smoothly.

The times run from 0 to 2 seconds, so `duration` is 2 and a loop wraps there.

Regenerate with:  python3 test/fixtures/make_hierarchy.py
"""

import json
import math
import struct
from pathlib import Path

HERE = Path(__file__).resolve().parent


def quad():
    """A unit quad in the XY plane at the origin, counter-clockwise from +Z."""
    positions = [
        (-0.4, -0.4, 0.0),
        (0.4, -0.4, 0.0),
        (0.4, 0.4, 0.0),
        (-0.4, 0.4, 0.0),
    ]
    normals = [(0.0, 0.0, 1.0)] * 4
    indices = [0, 1, 2, 0, 2, 3]
    return positions, normals, indices


def main() -> None:
    blob = bytearray()
    views = []
    accessors = []

    def add_view(data: bytes) -> int:
        while len(blob) % 4:
            blob.append(0)
        views.append({"buffer": 0, "byteOffset": len(blob), "byteLength": len(data)})
        blob.extend(data)
        return len(views) - 1

    def add_accessor(values, component_type, kind, pack_fmt, minmax=False) -> int:
        flat = []
        for v in values:
            flat.extend(v if isinstance(v, tuple) else [v])
        data = struct.pack("<" + pack_fmt * len(flat), *flat)
        view = add_view(data)
        acc = {
            "bufferView": view,
            "componentType": component_type,
            "count": len(values),
            "type": kind,
        }
        if minmax:
            rows = [v if isinstance(v, tuple) else (v,) for v in values]
            cols = list(zip(*rows))
            acc["min"] = [min(c) for c in cols]
            acc["max"] = [max(c) for c in cols]
        accessors.append(acc)
        return len(accessors) - 1

    def primitive():
        positions, normals, indices = quad()
        return {
            "attributes": {
                "POSITION": add_accessor(positions, 5126, "VEC3", "f", minmax=True),
                "NORMAL": add_accessor(normals, 5126, "VEC3", "f"),
            },
            "indices": add_accessor(indices, 5123, "SCALAR", "H"),
        }

    meshes = [
        # Two primitives, so `arm` instantiates as a group with two mesh children.
        {"name": "arm_mesh", "primitives": [primitive(), primitive()]},
        {"name": "tip_mesh", "primitives": [primitive()]},
        {"name": "loose_mesh", "primitives": [primitive()]},
    ]

    # A quarter turn about +Y, as glTF stores it: [x, y, z, w].
    half = math.pi / 4
    quarter_turn_y = [0.0, math.sin(half), 0.0, math.cos(half)]

    nodes = [
        {
            "name": "pivot",
            "translation": [2.0, 0.0, 0.0],
            "rotation": quarter_turn_y,
            "children": [1],
        },
        {"name": "arm", "mesh": 0, "scale": [2.0, 2.0, 2.0], "children": [2]},
        {"name": "tip", "mesh": 1, "translation": [1.0, 0.0, 0.0]},
        # Column-major, translation in the last column: (0, 3, 0).
        {
            "name": "loose",
            "mesh": 2,
            "matrix": [
                1.0, 0.0, 0.0, 0.0,
                0.0, 1.0, 0.0, 0.0,
                0.0, 0.0, 1.0, 0.0,
                0.0, 3.0, 0.0, 1.0,
            ],
        },
    ]

    # --- animations --------------------------------------------------------
    # Keyframe times are shared by every channel here; the accessors are not,
    # because each one carries its own required min/max and that is where the
    # clip's duration is read from.
    def times(values):
        return add_accessor(values, 5126, "SCALAR", "f", minmax=True)

    def vec3_keys(values):
        return add_accessor(values, 5126, "VEC3", "f")

    def vec4_keys(values):
        return add_accessor(values, 5126, "VEC4", "f")

    quarter = math.pi / 4
    half_turn_keys = [
        (0.0, 0.0, 0.0, 1.0),
        (0.0, math.sin(quarter), 0.0, math.cos(quarter)),
        (0.0, math.sin(quarter * 2), 0.0, math.cos(quarter * 2)),
    ]

    animations = [
        {
            "name": "slide",
            "samplers": [{
                "input": times([0.0, 2.0]),
                "output": vec3_keys([(1.0, 0.0, 0.0), (3.0, 0.0, 0.0)]),
                "interpolation": "LINEAR",
            }],
            "channels": [{"sampler": 0, "target": {"node": 2, "path": "translation"}}],
        },
        {
            "name": "spin",
            "samplers": [{
                "input": times([0.0, 1.0, 2.0]),
                "output": vec4_keys(half_turn_keys),
                "interpolation": "LINEAR",
            }],
            "channels": [{"sampler": 0, "target": {"node": 1, "path": "rotation"}}],
        },
        {
            "name": "blink",
            "samplers": [{
                "input": times([0.0, 1.0, 2.0]),
                "output": vec3_keys([(1.0, 1.0, 1.0), (3.0, 3.0, 3.0), (3.0, 3.0, 3.0)]),
                "interpolation": "STEP",
            }],
            "channels": [{"sampler": 0, "target": {"node": 3, "path": "scale"}}],
        },
    ]

    gltf = {
        "asset": {"version": "2.0", "generator": "three.c3 test fixture"},
        "scene": 0,
        "scenes": [{"nodes": [0, 3]}],
        "nodes": nodes,
        "meshes": meshes,
        "animations": animations,
        "accessors": accessors,
        "bufferViews": views,
        "buffers": [{"byteLength": len(blob)}],
    }

    json_bytes = json.dumps(gltf, separators=(",", ":")).encode()
    json_bytes += b" " * ((4 - len(json_bytes) % 4) % 4)
    bin_bytes = bytes(blob) + b"\x00" * ((4 - len(blob) % 4) % 4)

    glb = (
        b"glTF"
        + struct.pack("<II", 2, 12 + 8 + len(json_bytes) + 8 + len(bin_bytes))
        + struct.pack("<I", len(json_bytes)) + b"JSON" + json_bytes
        + struct.pack("<I", len(bin_bytes)) + b"BIN\x00" + bin_bytes
    )

    out = HERE / "hierarchy.glb"
    out.write_bytes(glb)
    print(f"wrote {out} ({len(glb)} bytes)")


if __name__ == "__main__":
    main()
