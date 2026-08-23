#!/usr/bin/env python3
"""Write test/fixtures/layered.glb — the fixture the material-layer checks assert on.

`CUSTOM_materials_layers` is a vendor extension (lib/gltf.c3l parses it; see
extensions/materials_layers.md in the exporter addon), so no exporter this
project can call writes one. It is generated here for `make_textured.py`'s
reason: the generator is checked in beside the .glb so what the binary contains
is readable rather than being a blob nobody can inspect.

What it contains, and why each piece is there:

  * `terrain` — a quad whose material carries a three-layer stack over a base
    material, which is the shape a splat map actually has. The three layers read
    R, G and B of ONE packed mask image, which is the economy the extension's
    per-layer `channel` field exists for and the thing the importer has to get
    right.
  * The three layers differ in every field the renderer reads: blend modes MIX,
    MULTIPLY and SCREEN; one inverted mask; a non-white baseColorFactor with a
    non-1 alpha on it; a per-layer `opacity` beside that alpha, so the check that
    the two are folded together has something to measure.
  * A layer with `enabled: false`, so the "a disabled layer uploads nothing"
    path is covered.
  * A layer whose mask `source` is `VERTEX_COLOR`, which this renderer cannot
    read at all. It is in the file on purpose: the importer must carry it across
    intact so the JS side can refuse it by name, and a fixture without one would
    let a loader that silently dropped it pass.
  * `weathered` — a second mesh whose one layer reads its mask from THE IMAGE
    `terrain` USES AS ITS BASE COLOUR. That is the colourspace check: image 0 is
    decoded once as sRGB for the base colour map and once as linear for the
    mask, so it must occupy two texture slots. A memo keyed on the image index
    alone hands the second caller the first one's format — the picture is right,
    nothing errors, and every weight is read through a transfer function it was
    never encoded with. It is also why the mask lives on a second mesh: the memo
    is per file, so the two readings have to come from different primitives for
    the sharing question to arise at all.
  * `plain` — a third mesh whose material has no extension, so "a file with
    layers still has meshes without them" is one file rather than two.

Regenerate with:  python3 test/fixtures/make_layered.py
"""

import json
import struct
import zlib
from pathlib import Path

HERE = Path(__file__).resolve().parent


def png_rgb(size: int, texel) -> bytes:
    """A solid or patterned RGB8 PNG. `texel(x, y)` answers an (r, g, b)."""
    rows = bytearray()
    for y in range(size):
        rows.append(0)  # filter byte: None
        for x in range(size):
            rows += bytes(texel(x, y))

    def chunk(tag: bytes, data: bytes) -> bytes:
        return (struct.pack(">I", len(data)) + tag + data
                + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF))

    ihdr = struct.pack(">IIBBBBB", size, size, 8, 2, 0, 0, 0)
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", ihdr)
            + chunk(b"IDAT", zlib.compress(bytes(rows), 9))
            + chunk(b"IEND", b""))


def splat(x: int, y: int):
    """A mask whose three channels are three different shapes, so a layer reading
    the wrong one is visible rather than plausible."""
    return (255 if x < 4 else 0, 255 if y < 4 else 0, 255 if (x + y) % 4 < 2 else 0)


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
    # The same bytes behind two glTF images — the colourspace-memo check.
    shared = png_rgb(8, lambda x, y: (200, 120, 60))
    mask_png = png_rgb(8, splat)
    rock_png = png_rgb(4, lambda x, y: (90, 90, 96))
    normal_png = png_rgb(4, lambda x, y: (128, 128, 255))

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

    primitives = []
    for x in (-1.6, 0.0, 1.6):
        positions, normals, uvs, indices = quad(x)
        primitives.append({
            "attributes": {
                "POSITION": add_accessor(positions, 5126, "VEC3", "f", minmax=True),
                "NORMAL": add_accessor(normals, 5126, "VEC3", "f"),
                "TEXCOORD_0": add_accessor(uvs, 5126, "VEC2", "f"),
            },
            "indices": add_accessor(indices, 5123, "SCALAR", "H"),
        })

    image_views = {
        "base": add_view(shared),
        "mask": add_view(mask_png),
        "rock": add_view(rock_png),
        "normal": add_view(normal_png),
        # Byte-identical to "base", read as linear by a layer's mask below.
        "twin": add_view(shared),
    }

    layers = [
        {
            "name": "rock",
            "pbrMetallicRoughness": {
                "baseColorFactor": [1.0, 1.0, 1.0, 1.0],
                "baseColorTexture": {"index": 2},
                # Parsed by gltf.c3l and deliberately dropped by the importer:
                # there is no specular term for them to feed (plan.md §12).
                "metallicFactor": 0.25,
                "roughnessFactor": 0.8,
            },
            "normalTexture": {"index": 3},
            "mask": {"source": "TEXTURE", "texture": {"index": 1}, "channel": "R"},
            "blendMode": "MIX",
            "opacity": 1.0,
            "enabled": True,
        },
        {
            "name": "moss",
            # A non-white factor with a non-1 alpha, beside a non-1 opacity: the
            # importer folds `opacity * baseColorFactor.a` into one number, and
            # 0.5 * 0.6 = 0.3 is a value neither of them has on its own.
            "pbrMetallicRoughness": {"baseColorFactor": [0.2, 0.6, 0.25, 0.6]},
            "mask": {"source": "TEXTURE", "texture": {"index": 1}, "channel": "G"},
            "blendMode": "MULTIPLY",
            "opacity": 0.5,
            "enabled": True,
        },
        {
            "name": "snow",
            "pbrMetallicRoughness": {"baseColorFactor": [0.95, 0.97, 1.0, 1.0]},
            "emissiveFactor": [0.1, 0.1, 0.12],
            "mask": {
                "source": "TEXTURE",
                "texture": {"index": 1},
                "channel": "B",
                "invert": True,
            },
            "blendMode": "SCREEN",
            "opacity": 1.0,
            "enabled": True,
        },
        {
            "name": "off",
            # Enabled false: its images must not be uploaded at all.
            "pbrMetallicRoughness": {"baseColorTexture": {"index": 4}},
            "mask": {"source": "TEXTURE", "texture": {"index": 1}, "channel": "A"},
            "blendMode": "ADD",
            "enabled": False,
        },
        {
            "name": "painted",
            # A mask this renderer cannot read. It must survive the import so the
            # JS side can refuse it by name rather than silently covering
            # everything.
            "pbrMetallicRoughness": {"baseColorFactor": [1.0, 0.0, 0.0, 1.0]},
            "mask": {"source": "VERTEX_COLOR", "attribute": "COLOR_0", "channel": "R"},
            "blendMode": "OVERLAY",
            "enabled": True,
        },
    ]

    gltf = {
        "asset": {"version": "2.0", "generator": "three.c3 test fixture"},
        "extensionsUsed": ["CUSTOM_materials_layers"],
        "scene": 0,
        "scenes": [{"nodes": [0, 1, 2]}],
        "nodes": [
            {"name": "terrain", "mesh": 0},
            {"name": "weathered", "mesh": 1},
            {"name": "plain", "mesh": 2},
        ],
        "meshes": [
            {"name": "terrain", "primitives": [dict(primitives[0], material=0)]},
            {"name": "weathered", "primitives": [dict(primitives[1], material=2)]},
            {"name": "plain", "primitives": [dict(primitives[2], material=1)]},
        ],
        "materials": [
            {
                "name": "ground",
                "pbrMetallicRoughness": {
                    "baseColorTexture": {"index": 0},
                    "baseColorFactor": [1.0, 1.0, 1.0, 1.0],
                },
                "extensions": {
                    "CUSTOM_materials_layers": {
                        "base": {"heightTexture": {"index": 2}, "bump": {"strength": 0.5, "distance": 0.1}},
                        "layers": layers,
                    }
                },
            },
            # No extension at all: a file with layers still has meshes without.
            {
                "name": "flat",
                "pbrMetallicRoughness": {"baseColorFactor": [0.4, 0.4, 0.45, 1.0]},
            },
            # One layer, masked by the image `ground` uses as its BASE COLOUR.
            # Image 0 therefore has to be decoded twice — sRGB there, linear here.
            {
                "name": "weathering",
                "pbrMetallicRoughness": {"baseColorFactor": [1.0, 1.0, 1.0, 1.0]},
                "extensions": {
                    "CUSTOM_materials_layers": {
                        "layers": [
                            {
                                "name": "grime",
                                "pbrMetallicRoughness": {"baseColorFactor": [0.3, 0.28, 0.24, 1.0]},
                                "mask": {"source": "TEXTURE", "texture": {"index": 0}, "channel": "G"},
                                "blendMode": "MULTIPLY",
                                "opacity": 1.0,
                                "enabled": True,
                            }
                        ]
                    }
                },
            },
        ],
        "textures": [
            {"source": 0},  # base colour, sRGB
            {"source": 1},  # the packed mask, linear
            {"source": 2},  # rock albedo, sRGB
            {"source": 3},  # rock normal, linear
            {"source": 4},  # twin of the base image, reached only by a disabled layer
        ],
        "images": [
            {"name": "ground", "mimeType": "image/png", "bufferView": image_views["base"]},
            {"name": "splat", "mimeType": "image/png", "bufferView": image_views["mask"]},
            {"name": "rock", "mimeType": "image/png", "bufferView": image_views["rock"]},
            {"name": "rock_n", "mimeType": "image/png", "bufferView": image_views["normal"]},
            {"name": "ground_twin", "mimeType": "image/png", "bufferView": image_views["twin"]},
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

    out = HERE / "layered.glb"
    out.write_bytes(glb)
    print(f"wrote {out} ({len(glb)} bytes)")


if __name__ == "__main__":
    main()
