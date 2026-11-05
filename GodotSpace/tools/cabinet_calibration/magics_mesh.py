"""Read geometry from the MT ZIP variant found in the supplied .magics file.

Only mesh blobs and a thumbnail are decoded, never encrypted header.xml.
Format cross-reference (not copied implementation):
https://github.com/SlicerHeart/SlicerHeart/blob/master/Docs/ImportMimics.md
Integer coordinates use an explicit, overridable 1e-7 meters/unit hypothesis.
"""
from __future__ import annotations

import argparse
import io
import json
from pathlib import Path
import struct
import zipfile

import numpy as np
import trimesh

from geometry import sha256

MAX_ARCHIVE_BYTES = 512 * 1024 * 1024
MAX_MEMBER_BYTES = 256 * 1024 * 1024


def open_mt_archive(path: Path) -> zipfile.ZipFile:
    if path.stat().st_size > MAX_ARCHIVE_BYTES:
        raise ValueError("MT archive exceeds size limit")
    data = bytearray(path.read_bytes())
    end = data.rfind(b"MT\x05\x06", max(0, len(data) - 65557))
    if end < 0 or end + 22 > len(data):
        raise ValueError("Missing MT central directory")
    _, disk, cd_disk, disk_count, count, cd_size, cd_offset, comment_size = struct.unpack_from(
        "<4s4H2IH", data, end)
    if disk or cd_disk or disk_count != count or count == 65535:
        raise ValueError("Multi-disk and ZIP64 MT files are unsupported")
    if end + 22 + comment_size != len(data) or cd_offset + cd_size != end:
        raise ValueError("Invalid MT directory bounds")
    data[end:end + 2] = b"PK"
    position = cd_offset
    for _ in range(count):
        if position + 46 > end or data[position:position + 4] != b"MT\x01\x02":
            raise ValueError("Invalid MT directory entry")
        name_len, extra_len, comment_len = struct.unpack_from("<3H", data, position + 28)
        local_offset = struct.unpack_from("<I", data, position + 42)[0]
        if local_offset + 30 > cd_offset or data[local_offset:local_offset + 4] != b"MT\x03\x04":
            raise ValueError("Invalid MT member offset")
        data[position:position + 2] = b"PK"
        data[local_offset:local_offset + 2] = b"PK"
        position += 46 + name_len + extra_len + comment_len
    if position != end:
        raise ValueError("MT directory length mismatch")
    archive = zipfile.ZipFile(io.BytesIO(data))
    if len(set(archive.namelist())) != len(archive.namelist()):
        raise ValueError("Duplicate MT members")
    if any(item.file_size > MAX_MEMBER_BYTES or item.flag_bits & 1
           for item in archive.infolist()):
        raise ValueError("Unsupported encrypted or oversized MT member")
    return archive


def convert(path: Path, output: Path, integer_unit_to_m: float = 1e-7) -> dict:
    if not np.isfinite(integer_unit_to_m) or integer_unit_to_m <= 0:
        raise ValueError("Coordinate unit must be finite and positive")
    output.mkdir(parents=True, exist_ok=True)
    parts = []
    with open_mt_archive(path) as archive:
        for name in archive.namelist():
            if not name.startswith("Stl") or not name.endswith("_vertices"):
                continue
            surface_name = name.removesuffix("_vertices") + "_surfaces"
            if surface_name not in archive.namelist():
                continue
            raw_vertices, raw_faces = archive.read(name), archive.read(surface_name)
            if len(raw_vertices) % 12 or len(raw_faces) % 12:
                raise ValueError("Mesh blob is not int32 triplets")
            vertices = np.frombuffer(raw_vertices, dtype="<i4").reshape(-1, 3)
            faces = np.frombuffer(raw_faces, dtype="<i4").reshape(-1, 3)
            if not len(vertices) or not len(faces) or faces.min() < 0 or faces.max() >= len(vertices):
                raise ValueError("Invalid mesh indices")
            mesh = trimesh.Trimesh(vertices.astype(float) * integer_unit_to_m,
                                   faces, process=False)
            row = {"blob": name.removesuffix("_vertices"), "vertices": len(vertices),
                   "triangles": len(faces), "bounds_m": mesh.bounds.tolist(),
                   "extents_m": mesh.extents.tolist()}
            # Preserve full geometry. Simplification is a separate, inspectable
            # Blender step; aggressive vertex clustering damages thin CAD panels.
            file_stem = f"magics_{len(parts):02d}"
            mesh.export(output / (file_stem + "_full.ply"))
            row.update(file=file_stem + "_full.ply",
                       sha256=sha256(output / (file_stem + "_full.ply")))
            parts.append(row)
        if "preview_128x128" in archive.namelist():
            (output / "source_preview.jpg").write_bytes(archive.read("preview_128x128"))
    if not parts:
        raise ValueError("No supported mesh pairs found")
    report = {"schema_version": 1, "source_file": path.name, "source_sha256": sha256(path),
              "integer_unit_to_m": integer_unit_to_m,
              "metadata_decoded": False,
              "coordinate_system": "original_magics_axes",
              "limitations": [
                  "Encrypted header.xml is not decoded; names, transforms and print settings unknown.",
                  "Inspect rendered geometry before treating raw mesh coordinates as an assembly.",
                  "Coordinate unit is an explicit hypothesis; validate against STL/model dimensions.",
              ], "parts": parts}
    (output / "magics_report.json").write_text(
        json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
    return report


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--integer-unit-to-m", type=float, default=1e-7)
    args = parser.parse_args()
    print(json.dumps(convert(args.source, args.output, args.integer_unit_to_m),
                     ensure_ascii=False, indent=2))
