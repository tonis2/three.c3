#!/usr/bin/env python3
"""Write test/fixtures/shared_material.glb — the fixture the decode memo asserts on.

`textured.glb` is the opposite fixture and they are worth reading together. That
one has two *distinct* images whose bytes happen to match, which is what the
content hash exists to catch. This one has one image named by four meshes, which
the hash catches far too late: the dedup runs on the decoded RGBA, so the PNG is
decoded, converted and hashed once per primitive and then thrown away three
times.

That is the shape a real kit has — one atlas, N pieces — so it is the shape the
memo has to be measured on. Four meshes rather than two so the number a broken
memo reports (4) cannot be confused with an off-by-one.

  * Four meshes, `piece_0` .. `piece_3`, one quad each.
  * One glTF image, one texture, one material, named by all four.

Regenerate with:  python3 test/fixtures/make_shared_material.py
"""

import json
import struct
import zlib
from pathlib import Path

HERE = Path(__file__).resolve().parent

PIECES = 4


def png_checker() -> bytes:
    """An 8x8 magenta/black checkerboard, RGB8 — the same image `textured.glb`
    uses, so a test that renders this fixture can assert the same hues."""
    size = 8
    rows = bytearray()
    for y in range(size):
        rows.append(0)  # filter byte: None
        for x in range(size):
            on = (x // 2 + y // 2) % 2 == 0
            rows += bytes((255, 0, 255) if on else (16, 16, 16))

    def chunk(tag: bytes, data: bytes) -> bytes:
        return (struct.pack(">I", len(data)) + tag + data
                + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF))

    ihdr = struct.pack(">IIBBBBB", size, size, 8, 2, 0, 0, 0)
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", ihdr)
            + chunk(b"IDAT", zlib.compress(bytes(rows), 9))
            + chunk(b"IEND", b""))


def quad(x_offset: float):
    """A unit quad in the XY plane, counter-clockwise seen from +Z — glTF's
    front-face convention, so it survives backface culling."""
    positions = [
        (x_offset - 0.4, -0.4, 0.0),
        (x_offset + 0.4, -0.4, 0.0),
        (x_offset + 0.4, 0.4, 0.0),
        (x_offset - 0.4, 0.4, 0.0),
    ]
    normals = [(0.0, 0.0, 1.0)] * 4
    uvs = [(0.0, 1.0), (1.0, 1.0), (1.0, 0.0), (0.0, 0.0)]
    indices = [0, 1, 2, 0, 2, 3]
    return positions, normals, uvs, indices


def main() -> None:
    png = png_checker()

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
            cols = list(zip(*values))
            acc["min"] = [min(c) for c in cols]
            acc["max"] = [max(c) for c in cols]
        accessors.append(acc)
        return len(accessors) - 1

    meshes, nodes = [], []
    for i in range(PIECES):
        positions, normals, uvs, indices = quad(-1.35 + i * 0.9)
        meshes.append({
            "name": f"piece_{i}",
            "primitives": [{
                "attributes": {
                    "POSITION": add_accessor(positions, 5126, "VEC3", "f", minmax=True),
                    "NORMAL": add_accessor(normals, 5126, "VEC3", "f"),
                    "TEXCOORD_0": add_accessor(uvs, 5126, "VEC2", "f"),
                },
                "indices": add_accessor(indices, 5123, "SCALAR", "H"),
                # Every piece, the same material — the whole point of the file.
                "material": 0,
            }],
        })
        nodes.append({"name": f"piece_{i}", "mesh": i})

    image_view = add_view(png)

    gltf = {
        "asset": {"version": "2.0", "generator": "three.c3 test fixture"},
        "scene": 0,
        "scenes": [{"nodes": list(range(PIECES))}],
        "nodes": nodes,
        "meshes": meshes,
        "materials": [
            {
                "name": "atlas",
                "pbrMetallicRoughness": {
                    "baseColorTexture": {"index": 0},
                    "baseColorFactor": [1.0, 1.0, 1.0, 1.0],
                },
            },
        ],
        "textures": [{"source": 0}],
        "images": [
            {"name": "atlas", "mimeType": "image/png", "bufferView": image_view},
        ],
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

    out = HERE / "shared_material.glb"
    out.write_bytes(glb)
    print(f"wrote {out} ({len(glb)} bytes)")


if __name__ == "__main__":
    main()
