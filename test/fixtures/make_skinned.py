#!/usr/bin/env python3
"""Write test/fixtures/skinned.glb — the fixture every skinning check asserts on.

The other fixtures place geometry with node transforms or bake it into the
vertices. This one is posed by a *skeleton*, which is the third way a glTF can
say where its triangles are and the only one where the answer changes per frame.

## The geometry

A flat ribbon in the XY plane, six vertices in three rows at y = 0, 1 and 2,
0.4 wide, facing +Z. Four triangles. Deliberately tiny: every check here is
about where a vertex ends up, and a vertex you can name is worth more than a
mesh that looks like something.

## The skeleton, and why the numbers are what they are

Two joints. `Root` at the origin; `Mid` its child, translated to (0, 1, 0).
Weights are **hard-assigned rather than blended** — rows y=0 and y=1 ride `Root`
with weight 1, row y=2 rides `Mid` with weight 1 — so the posed position of
every vertex is one matrix multiply that a test can do by hand. A blended row
would test the same code and be checkable only against a number this script also
computed, which is a test agreeing with itself.

The bind pose therefore gives inverse bind matrices of exactly `identity` and
`translate(0, -1, 0)`, and at rest every skin matrix is the identity — which is
the first thing the bake is checked against, because a rest pose that is *not*
identity means the inverse bind and the node transforms disagree and every other
number downstream is wrong by the same amount.

`Bend` rotates `Mid` a quarter turn about +Z over one second. At t=1 the tip
vertex (0.2, 2, 0) goes:

    translate(0,-1,0) -> (0.2, 1, 0)
    rotate z 90       -> (-1, 0.2, 0)
    translate(0,1,0)  -> (-1, 1.2, 0)

so the bar folds to the left and the tip lands somewhere no static pose puts it.
That is the pixel the render check looks at.

`Twist` is a second clip — a half turn about +Y on the same joint — and exists so
the pose buffer holds more than one baked segment and the layout check has two
offsets that must not overlap.

## The prop

`Prop` is a second mesh parented to the `Mid` **joint**. It is what the pruning
rule is checked against: joint nodes with nothing under them are dropped when a
character is instantiated without a skeleton, and a joint holding a prop is not,
or the prop is orphaned. A file without one would let a prune that is too greedy
pass every test.

JOINTS_0 is written as unsigned byte, which is what Blender exports for a rig
this small and what exercises the widening path on the way to a uint4.

Regenerate with:  python3 test/fixtures/make_skinned.py
"""

import json
import math
import struct
from pathlib import Path

HERE = Path(__file__).resolve().parent


def ribbon():
    """Three rows of two vertices, bottom to top, facing +Z."""
    positions = [
        (-0.2, 0.0, 0.0), (0.2, 0.0, 0.0),
        (-0.2, 1.0, 0.0), (0.2, 1.0, 0.0),
        (-0.2, 2.0, 0.0), (0.2, 2.0, 0.0),
    ]
    normals = [(0.0, 0.0, 1.0)] * 6
    # Rows 0 and 1 ride Root; row 2 rides Mid. One joint per vertex, weight 1.
    joints = [(0, 0, 0, 0)] * 4 + [(1, 0, 0, 0)] * 2
    weights = [(1.0, 0.0, 0.0, 0.0)] * 6
    indices = [0, 1, 3, 0, 3, 2, 2, 3, 5, 2, 5, 4]
    return positions, normals, joints, weights, indices


def prop():
    """A small unskinned quad, for the node parented into the skeleton."""
    positions = [
        (-0.1, -0.1, 0.0), (0.1, -0.1, 0.0),
        (0.1, 0.1, 0.0), (-0.1, 0.1, 0.0),
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

    positions, normals, joints, weights, indices = ribbon()
    bar = {
        "attributes": {
            "POSITION": add_accessor(positions, 5126, "VEC3", "f", minmax=True),
            "NORMAL": add_accessor(normals, 5126, "VEC3", "f"),
            "JOINTS_0": add_accessor(joints, 5121, "VEC4", "B"),
            "WEIGHTS_0": add_accessor(weights, 5126, "VEC4", "f"),
        },
        "indices": add_accessor(indices, 5123, "SCALAR", "H"),
    }

    prop_positions, prop_normals, prop_indices = prop()
    prop_primitive = {
        "attributes": {
            "POSITION": add_accessor(prop_positions, 5126, "VEC3", "f", minmax=True),
            "NORMAL": add_accessor(prop_normals, 5126, "VEC3", "f"),
        },
        "indices": add_accessor(prop_indices, 5123, "SCALAR", "H"),
    }

    meshes = [
        {"name": "Bar", "primitives": [bar]},
        {"name": "Prop", "primitives": [prop_primitive]},
    ]

    # Column-major, as glTF stores a matrix. Root's bind transform is the
    # identity and Mid's is translate(0, 1, 0), so the inverses are the identity
    # and translate(0, -1, 0).
    identity = (
        1.0, 0.0, 0.0, 0.0,
        0.0, 1.0, 0.0, 0.0,
        0.0, 0.0, 1.0, 0.0,
        0.0, 0.0, 0.0, 1.0,
    )
    down_one = (
        1.0, 0.0, 0.0, 0.0,
        0.0, 1.0, 0.0, 0.0,
        0.0, 0.0, 1.0, 0.0,
        0.0, -1.0, 0.0, 1.0,
    )
    inverse_binds = add_accessor([identity, down_one], 5126, "MAT4", "f")

    half = math.pi / 4
    quarter_turn_z = (0.0, 0.0, math.sin(half), math.cos(half))
    half_turn_y = (0.0, 1.0, 0.0, 0.0)
    no_turn = (0.0, 0.0, 0.0, 1.0)

    times = add_accessor([0.0, 1.0], 5126, "SCALAR", "f", minmax=True)
    bend_values = add_accessor([no_turn, quarter_turn_z], 5126, "VEC4", "f")
    twist_values = add_accessor([no_turn, half_turn_y], 5126, "VEC4", "f")

    def clip(name, sampler_output):
        return {
            "name": name,
            "samplers": [
                {"input": times, "output": sampler_output, "interpolation": "LINEAR"}
            ],
            # Node 2 is Mid, the joint both clips drive.
            "channels": [{"sampler": 0, "target": {"node": 2, "path": "rotation"}}],
        }

    animations = [clip("Bend", bend_values), clip("Twist", twist_values)]

    nodes = [
        # The skinned mesh. Its own transform is ignored by the spec, so it is
        # the identity here — which is also what every real exporter writes.
        {"name": "Character", "mesh": 0, "skin": 0},
        {"name": "Root", "children": [2]},
        {"name": "Mid", "translation": [0.0, 1.0, 0.0], "children": [3]},
        # Parented to a joint, and carrying geometry: the node the prune must keep.
        {"name": "Prop", "mesh": 1, "translation": [0.3, 0.0, 0.0]},
    ]

    gltf = {
        "asset": {"version": "2.0", "generator": "make_skinned.py"},
        "scene": 0,
        "scenes": [{"nodes": [0, 1]}],
        "nodes": nodes,
        "meshes": meshes,
        "skins": [
            {"name": "Rig", "joints": [1, 2], "inverseBindMatrices": inverse_binds}
        ],
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

    out = HERE / "skinned.glb"
    out.write_bytes(glb)
    print(f"wrote {out} ({len(glb)} bytes)")


if __name__ == "__main__":
    main()
