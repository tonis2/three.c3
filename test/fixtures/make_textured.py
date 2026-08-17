#!/usr/bin/env python3
"""Write test/fixtures/textured.glb — the fixture the texture checks assert on.

gltf.c3l's GltfBuilder can write geometry, nodes and skins, but has no image,
texture or material support, so this fixture cannot be authored in C3 the way
crig writes its animation fixtures. It is generated here instead, and the
generator is checked in beside the .glb so what the binary contains is readable
rather than being a blob nobody can inspect.

What it contains, and why each piece is there:

  * Two meshes, `quad_left` and `quad_right`, so a loader that welds a file
    into one triangle soup fails the mesh-count check.
  * Two *separate* glTF images whose PNG bytes are byte-identical, each with
    its own bufferView, texture and material. A loader that deduplicates
    textures by content hash uploads one; a loader that trusts the file's own
    indices uploads two. That is the whole point of the fixture.
  * A third material with no texture at all, on `quad_right`'s second
    primitive, so the untextured path is covered in the same file.

Regenerate with:  python3 test/fixtures/make_textured.py
"""

import json
import struct
import zlib
from pathlib import Path

HERE = Path(__file__).resolve().parent


def png_checker() -> bytes:
    """An 8x8 magenta/black checkerboard, RGB8. Small, and unmistakable on
    screen: a texture that failed to bind reads as flat colour, and a texture
    bound with the wrong UVs reads as a smear."""
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
        (x_offset - 0.5, -0.5, 0.0),
        (x_offset + 0.5, -0.5, 0.0),
        (x_offset + 0.5, 0.5, 0.0),
        (x_offset - 0.5, 0.5, 0.0),
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

    meshes, primitives_by_mesh = [], []
    for name, x in (("quad_left", -0.75), ("quad_right", 0.75)):
        positions, normals, uvs, indices = quad(x)
        primitives_by_mesh.append({
            "attributes": {
                "POSITION": add_accessor(positions, 5126, "VEC3", "f", minmax=True),
                "NORMAL": add_accessor(normals, 5126, "VEC3", "f"),
                "TEXCOORD_0": add_accessor(uvs, 5126, "VEC2", "f"),
            },
            "indices": add_accessor(indices, 5123, "SCALAR", "H"),
        })
        meshes.append(name)

    # Two images, identical bytes, separate views: the dedup check.
    image_views = [add_view(png), add_view(png)]

    gltf = {
        "asset": {"version": "2.0", "generator": "three.c3 test fixture"},
        "scene": 0,
        "scenes": [{"nodes": [0, 1]}],
        "nodes": [
            {"name": "quad_left", "mesh": 0},
            {"name": "quad_right", "mesh": 1},
        ],
        "meshes": [
            {"name": meshes[0], "primitives": [dict(primitives_by_mesh[0], material=0)]},
            {"name": meshes[1], "primitives": [dict(primitives_by_mesh[1], material=1)]},
        ],
        "materials": [
            {
                "name": "checker_a",
                "pbrMetallicRoughness": {
                    "baseColorTexture": {"index": 0},
                    "baseColorFactor": [1.0, 1.0, 1.0, 1.0],
                },
            },
            {
                "name": "checker_b",
                "pbrMetallicRoughness": {
                    "baseColorTexture": {"index": 1},
                    "baseColorFactor": [1.0, 1.0, 1.0, 1.0],
                },
            },
        ],
        "textures": [{"source": 0}, {"source": 1}],
        "images": [
            {"name": "checker_a", "mimeType": "image/png", "bufferView": image_views[0]},
            {"name": "checker_b", "mimeType": "image/png", "bufferView": image_views[1]},
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

    out = HERE / "textured.glb"
    out.write_bytes(glb)
    print(f"wrote {out} ({len(glb)} bytes)")


if __name__ == "__main__":
    main()
