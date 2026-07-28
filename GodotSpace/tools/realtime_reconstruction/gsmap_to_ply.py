#!/usr/bin/env python3
"""Convert a GodotSpace GSM1 reconstruction map to a colored PLY point cloud."""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import struct
import sys
import tempfile
from dataclasses import dataclass
from typing import BinaryIO, Iterator, Sequence


GSM_MAGIC = b"GSM1"
GSM_VERSION = 1
GSM_HEADER = struct.Struct(">4sHHIIIIQII32s")
GSM_HEADER_SIZE = 72
GSM_ENTRY_HEADER = struct.Struct(">I32s")
GSM_MAX_MANIFEST_BYTES = 1024 * 1024
GSM_MAX_PACKAGE_BYTES = 64 * 1024 * 1024

PCCH_MAGIC = b"PCCH"
PCCH_VERSION = 1
PCCH_HEADER = struct.Struct(">4sHHIIIIII32s")
PCCH_HEADER_SIZE = 64
PCCH_FLAG_CONFIDENCE = 1
PCCH_FLAG_CAMERA_POSE = 2
PCCH_KNOWN_FLAGS = PCCH_FLAG_CONFIDENCE | PCCH_FLAG_CAMERA_POSE
PCCH_MAX_ENCODED_BYTES = 32 * 1024 * 1024


class GsmapFormatError(ValueError):
    """Raised when a GSM1 or PCCH integrity/format check fails."""


@dataclass(frozen=True)
class PointChunk:
    point_count: int
    point_data: memoryview
    has_confidence: bool
    metadata: dict[str, object]


@dataclass(frozen=True)
class Gsmap:
    manifest: dict[str, object]
    chunks: tuple[PointChunk, ...]
    point_count: int


@dataclass(frozen=True)
class Sim3:
    scale: float
    rotation_wxyz: tuple[float, float, float, float]
    translation_xyz: tuple[float, float, float]

    def apply(self, point: tuple[float, float, float]) -> tuple[float, float, float]:
        w, qx, qy, qz = self.rotation_wxyz
        px, py, pz = point

        # Rotate with q * point * conjugate(q), then apply uniform scale/translation.
        tx = 2.0 * (qy * pz - qz * py)
        ty = 2.0 * (qz * px - qx * pz)
        tz = 2.0 * (qx * py - qy * px)
        rx = px + w * tx + (qy * tz - qz * ty)
        ry = py + w * ty + (qz * tx - qx * tz)
        rz = pz + w * tz + (qx * ty - qy * tx)

        ox, oy, oz = self.translation_xyz
        return (
            rx * self.scale + ox,
            ry * self.scale + oy,
            rz * self.scale + oz,
        )


def _fail(message: str) -> None:
    raise GsmapFormatError(message)


def _sha256(data: bytes | memoryview) -> bytes:
    return hashlib.sha256(data).digest()


def _read_json(data: memoryview, label: str) -> dict[str, object]:
    try:
        decoded = bytes(data).decode("utf-8")
    except UnicodeDecodeError as error:
        raise GsmapFormatError(f"{label} is not valid UTF-8") from error
    try:
        value = json.loads(decoded)
    except json.JSONDecodeError as error:
        raise GsmapFormatError(f"{label} is not valid JSON: {error}") from error
    if not isinstance(value, dict):
        _fail(f"{label} root must be an object")
    return value


def _require_int(value: object, label: str, minimum: int = 0) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or value < minimum:
        _fail(f"{label} must be an integer >= {minimum}")
    return value


def _decode_pcch(encoded: memoryview, chunk_index: int) -> PointChunk:
    if len(encoded) < PCCH_HEADER_SIZE:
        _fail(f"chunk {chunk_index}: PCCH header is incomplete")
    if len(encoded) > PCCH_MAX_ENCODED_BYTES:
        _fail(f"chunk {chunk_index}: PCCH size exceeds the supported limit")

    (
        magic,
        version,
        header_size,
        flags,
        point_count,
        metadata_size,
        point_data_size,
        total_size,
        reserved,
        declared_body_digest,
    ) = PCCH_HEADER.unpack_from(encoded)

    if magic != PCCH_MAGIC:
        _fail(f"chunk {chunk_index}: invalid PCCH magic")
    if version != PCCH_VERSION or header_size != PCCH_HEADER_SIZE:
        _fail(f"chunk {chunk_index}: unsupported PCCH version/header")
    if flags & ~PCCH_KNOWN_FLAGS:
        _fail(f"chunk {chunk_index}: unknown PCCH flags 0x{flags:x}")
    if reserved != 0:
        _fail(f"chunk {chunk_index}: reserved PCCH field is not zero")
    if point_count <= 0:
        _fail(f"chunk {chunk_index}: point count must be positive")
    if metadata_size <= 0:
        _fail(f"chunk {chunk_index}: metadata is empty")
    if total_size != len(encoded):
        _fail(f"chunk {chunk_index}: declared PCCH size does not match entry size")

    has_confidence = bool(flags & PCCH_FLAG_CONFIDENCE)
    stride = 16 if has_confidence else 15
    if point_data_size != point_count * stride:
        _fail(f"chunk {chunk_index}: point data size is inconsistent with its count")
    if header_size + metadata_size + point_data_size != len(encoded):
        _fail(f"chunk {chunk_index}: PCCH section sizes do not add up")

    body = encoded[header_size:]
    if _sha256(body) != declared_body_digest:
        _fail(f"chunk {chunk_index}: PCCH body SHA-256 check failed")

    metadata_end = header_size + metadata_size
    metadata = _read_json(encoded[header_size:metadata_end], f"chunk {chunk_index} metadata")
    if metadata.get("coordinate_space") != "lingbot_world":
        _fail(f"chunk {chunk_index}: unsupported coordinate space")
    if metadata.get("position_unit") != "lingbot_model_unit":
        _fail(f"chunk {chunk_index}: unsupported position unit")

    return PointChunk(
        point_count=point_count,
        point_data=encoded[metadata_end:],
        has_confidence=has_confidence,
        metadata=metadata,
    )


def read_gsmap(path: Path) -> Gsmap:
    try:
        data = path.read_bytes()
    except OSError as error:
        raise GsmapFormatError(f"cannot read input file: {error}") from error

    if len(data) < GSM_HEADER_SIZE:
        _fail("GSM1 header is incomplete")
    if len(data) > GSM_MAX_PACKAGE_BYTES:
        _fail("GSM1 package exceeds the supported 64 MiB limit")

    (
        magic,
        version,
        header_size,
        reserved_0,
        manifest_size,
        chunk_count,
        declared_point_count,
        total_size,
        body_size,
        reserved_1,
        declared_body_digest,
    ) = GSM_HEADER.unpack_from(data)

    if magic != GSM_MAGIC:
        _fail("invalid GSM1 magic")
    if version != GSM_VERSION or header_size != GSM_HEADER_SIZE:
        _fail("unsupported GSM1 version/header")
    if reserved_0 != 0 or reserved_1 != 0:
        _fail("reserved GSM1 header field is not zero")
    if not 0 < manifest_size <= GSM_MAX_MANIFEST_BYTES:
        _fail("manifest size is outside the supported range")
    if chunk_count <= 0 or declared_point_count <= 0:
        _fail("GSM1 chunk and point counts must be positive")
    if total_size != len(data) or body_size != len(data) - header_size:
        _fail("declared GSM1 package size does not match the file")

    package = memoryview(data)
    body = package[header_size:]
    if _sha256(body) != declared_body_digest:
        _fail("GSM1 body SHA-256 check failed")
    if manifest_size > len(body):
        _fail("manifest extends beyond the GSM1 body")

    manifest = _read_json(body[:manifest_size], "GSM1 manifest")
    if manifest.get("format") != "GodotSpace Realtime Reconstruction Map":
        _fail("unsupported GSM1 manifest format")
    if manifest.get("format_version") != GSM_VERSION:
        _fail("unsupported GSM1 manifest version")
    if manifest.get("package_encoding") != "GSM1-manifest-plus-PCCH":
        _fail("unsupported GSM1 package encoding")
    if _require_int(manifest.get("chunk_count"), "manifest chunk_count", 1) != chunk_count:
        _fail("manifest chunk count does not match the GSM1 header")
    if (
        _require_int(manifest.get("point_count"), "manifest point_count", 1)
        != declared_point_count
    ):
        _fail("manifest point count does not match the GSM1 header")

    records = manifest.get("chunks")
    if not isinstance(records, list) or len(records) != chunk_count:
        _fail("manifest chunk records do not match the GSM1 header")

    chunks: list[PointChunk] = []
    decoded_point_count = 0
    cursor = manifest_size
    for chunk_index, record in enumerate(records):
        if cursor + GSM_ENTRY_HEADER.size > len(body):
            _fail(f"chunk {chunk_index}: entry header is incomplete")
        encoded_size, declared_entry_digest = GSM_ENTRY_HEADER.unpack_from(body, cursor)
        cursor += GSM_ENTRY_HEADER.size
        if not 0 < encoded_size <= PCCH_MAX_ENCODED_BYTES:
            _fail(f"chunk {chunk_index}: entry size is outside the supported range")
        encoded_end = cursor + encoded_size
        if encoded_end > len(body):
            _fail(f"chunk {chunk_index}: entry payload is incomplete")

        encoded = body[cursor:encoded_end]
        cursor = encoded_end
        if _sha256(encoded) != declared_entry_digest:
            _fail(f"chunk {chunk_index}: entry SHA-256 check failed")
        if not isinstance(record, dict):
            _fail(f"chunk {chunk_index}: manifest record is not an object")
        if record.get("index") != chunk_index:
            _fail(f"chunk {chunk_index}: manifest index does not match")
        if record.get("byte_length") != encoded_size:
            _fail(f"chunk {chunk_index}: manifest byte length does not match")
        if record.get("sha256") != declared_entry_digest.hex():
            _fail(f"chunk {chunk_index}: manifest SHA-256 does not match")

        chunk = _decode_pcch(encoded, chunk_index)
        if record.get("point_count") != chunk.point_count:
            _fail(f"chunk {chunk_index}: manifest point count does not match")
        if record.get("chunk_id") != chunk.metadata.get("chunk_id"):
            _fail(f"chunk {chunk_index}: manifest chunk ID does not match")
        if chunk.metadata.get("session_id") != manifest.get("session_id"):
            _fail(f"chunk {chunk_index}: session ID does not match the map")
        if chunk.metadata.get("map_id") != manifest.get("map_id"):
            _fail(f"chunk {chunk_index}: map ID does not match the map")

        chunks.append(chunk)
        decoded_point_count += chunk.point_count

    if cursor != len(body):
        _fail("GSM1 package contains trailing bytes")
    if decoded_point_count != declared_point_count:
        _fail("decoded point count does not match the GSM1 header")
    return Gsmap(manifest, tuple(chunks), decoded_point_count)


def _read_sim3(registration: dict[str, object], field: str) -> Sim3:
    value = registration.get(field)
    if not isinstance(value, dict):
        _fail(f"registration.{field} is missing or invalid")

    scale_value = value.get("scale")
    rotation_value = value.get("rotation_wxyz")
    translation_value = value.get("translation_xyz")
    if isinstance(scale_value, bool) or not isinstance(scale_value, (int, float)):
        _fail(f"registration.{field}.scale is invalid")
    if not isinstance(rotation_value, list) or len(rotation_value) != 4:
        _fail(f"registration.{field}.rotation_wxyz is invalid")
    if not isinstance(translation_value, list) or len(translation_value) != 3:
        _fail(f"registration.{field}.translation_xyz is invalid")

    numbers = [float(scale_value), *map(float, rotation_value), *map(float, translation_value)]
    if not all(math.isfinite(number) for number in numbers) or numbers[0] <= 0.0:
        _fail(f"registration.{field} contains non-finite or invalid values")

    rotation = tuple(numbers[1:5])
    length = math.sqrt(sum(component * component for component in rotation))
    if length < 1e-8 or abs(length - 1.0) > 0.001:
        _fail(f"registration.{field} quaternion is not normalized")
    normalized = tuple(component / length for component in rotation)
    return Sim3(numbers[0], normalized, tuple(numbers[5:8]))


def _registration_chain(manifest: dict[str, object]) -> tuple[Sim3, Sim3, bool]:
    registration = manifest.get("registration")
    if not isinstance(registration, dict) or registration.get("schema_version") != 1:
        _fail("manifest registration schema is missing or unsupported")
    automatic = _read_sim3(registration, "automatic_sim3")
    manual = _read_sim3(registration, "manual_adjustment")
    confirmed = registration.get("confirmed")
    if not isinstance(confirmed, bool):
        _fail("manifest registration.confirmed is invalid")
    return automatic, manual, confirmed


def _iter_points(
    gsmap: Gsmap,
    apply_registration: bool,
) -> Iterator[tuple[float, float, float, int, int, int, int]]:
    transforms: tuple[Sim3, Sim3] | None = None
    if apply_registration:
        automatic, manual, _confirmed = _registration_chain(gsmap.manifest)
        transforms = (automatic, manual)

    for chunk in gsmap.chunks:
        input_struct = struct.Struct(">fffBBBB" if chunk.has_confidence else ">fffBBB")
        for row in input_struct.iter_unpack(chunk.point_data):
            x, y, z, red, green, blue = row[:6]
            if not all(math.isfinite(value) for value in (x, y, z)):
                _fail("point cloud contains a non-finite position")
            if transforms is not None:
                point = transforms[0].apply((x, y, z))
                x, y, z = transforms[1].apply(point)
            confidence = row[6] if chunk.has_confidence else 255
            yield x, y, z, red, green, blue, confidence


def _ply_header(
    gsmap: Gsmap,
    ascii_output: bool,
    apply_registration: bool,
    include_confidence: bool,
) -> bytes:
    lines = [
        "ply",
        f"format {'ascii' if ascii_output else 'binary_little_endian'} 1.0",
        "comment generated_by GodotSpace gsmap_to_ply.py",
        "comment source_format GSM1",
        f"comment source_coordinate_space {gsmap.manifest.get('coordinate_space', 'unknown')}",
        f"comment registration_applied {str(apply_registration).lower()}",
        f"element vertex {gsmap.point_count}",
        "property float x",
        "property float y",
        "property float z",
        "property uchar red",
        "property uchar green",
        "property uchar blue",
    ]
    if include_confidence:
        lines.append("property uchar confidence")
    lines.append("end_header")
    return ("\n".join(lines) + "\n").encode("ascii")


def _write_ascii_points(
    output: BinaryIO,
    points: Iterator[tuple[float, float, float, int, int, int, int]],
    include_confidence: bool,
) -> None:
    batch: list[str] = []
    for x, y, z, red, green, blue, confidence in points:
        line = f"{x:.9g} {y:.9g} {z:.9g} {red} {green} {blue}"
        if include_confidence:
            line += f" {confidence}"
        batch.append(line + "\n")
        if len(batch) >= 8192:
            output.write("".join(batch).encode("ascii"))
            batch.clear()
    if batch:
        output.write("".join(batch).encode("ascii"))


def _write_binary_points(
    output: BinaryIO,
    points: Iterator[tuple[float, float, float, int, int, int, int]],
    include_confidence: bool,
) -> None:
    output_struct = struct.Struct("<fffBBBB" if include_confidence else "<fffBBB")
    batch_size = 65536
    buffer = bytearray(output_struct.size * batch_size)
    used = 0
    for point in points:
        values: Sequence[float | int] = point if include_confidence else point[:6]
        output_struct.pack_into(buffer, used * output_struct.size, *values)
        used += 1
        if used == batch_size:
            output.write(buffer)
            used = 0
    if used:
        output.write(memoryview(buffer)[: used * output_struct.size])


def write_ply(
    gsmap: Gsmap,
    output_path: Path,
    *,
    ascii_output: bool,
    apply_registration: bool,
    include_confidence: bool,
    overwrite: bool,
) -> None:
    if output_path.exists() and not overwrite:
        _fail(f"output already exists (use --overwrite): {output_path}")
    output_path.parent.mkdir(parents=True, exist_ok=True)

    temporary_name: str | None = None
    try:
        with tempfile.NamedTemporaryFile(
            mode="w+b",
            dir=output_path.parent,
            prefix=f".{output_path.name}.",
            suffix=".tmp",
            delete=False,
        ) as output:
            temporary_name = output.name
            output.write(
                _ply_header(
                    gsmap,
                    ascii_output,
                    apply_registration,
                    include_confidence,
                )
            )
            points = _iter_points(gsmap, apply_registration)
            if ascii_output:
                _write_ascii_points(output, points, include_confidence)
            else:
                _write_binary_points(output, points, include_confidence)
            output.flush()
            os.fsync(output.fileno())
        os.replace(temporary_name, output_path)
        temporary_name = None
    finally:
        if temporary_name is not None:
            try:
                Path(temporary_name).unlink()
            except FileNotFoundError:
                pass


def _write_manifest_json(
    manifest: dict[str, object],
    path: Path,
    overwrite: bool,
) -> None:
    if path.exists() and not overwrite:
        _fail(f"manifest output already exists (use --overwrite): {path}")
    text = json.dumps(manifest, ensure_ascii=False, indent=2) + "\n"
    temporary_name: str | None = None
    try:
        with tempfile.NamedTemporaryFile(
            mode="w",
            encoding="utf-8",
            newline="\n",
            dir=path.parent,
            prefix=f".{path.name}.",
            suffix=".tmp",
            delete=False,
        ) as output:
            temporary_name = output.name
            output.write(text)
            output.flush()
            os.fsync(output.fileno())
        os.replace(temporary_name, path)
        temporary_name = None
    finally:
        if temporary_name is not None:
            try:
                Path(temporary_name).unlink()
            except FileNotFoundError:
                pass


def _parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Convert a GodotSpace GSM1 .gsmap file to a colored PLY file.",
    )
    parser.add_argument("input", type=Path, help="input .gsmap file")
    parser.add_argument(
        "-o",
        "--output",
        type=Path,
        help="output .ply path (default: beside the input file)",
    )
    parser.add_argument(
        "--ascii",
        action="store_true",
        help="write an ASCII PLY instead of compact binary little-endian PLY",
    )
    parser.add_argument(
        "--apply-registration",
        action="store_true",
        help="apply automatic and manual Sim(3) registration to every point",
    )
    parser.add_argument(
        "--include-confidence",
        action="store_true",
        help="include a confidence uchar property (missing values become 255)",
    )
    parser.add_argument(
        "--write-manifest",
        action="store_true",
        help="also write the GSM1 manifest beside the PLY as .manifest.json",
    )
    parser.add_argument(
        "--overwrite",
        action="store_true",
        help="replace existing output files",
    )
    return parser.parse_args()


def main() -> int:
    args = _parse_args()
    input_path = args.input.expanduser().resolve()
    output_path = (
        args.output.expanduser().resolve()
        if args.output is not None
        else input_path.with_suffix(".ply")
    )

    try:
        if output_path == input_path:
            _fail("input and output paths must be different")
        if output_path.suffix.lower() != ".ply":
            _fail("output path must use the .ply extension")
        manifest_path = output_path.with_suffix(".manifest.json")
        if args.write_manifest and manifest_path.exists() and not args.overwrite:
            _fail(f"manifest output already exists (use --overwrite): {manifest_path}")

        gsmap = read_gsmap(input_path)
        registration_confirmed: bool | None = None
        if args.apply_registration:
            _automatic, _manual, registration_confirmed = _registration_chain(gsmap.manifest)
        write_ply(
            gsmap,
            output_path,
            ascii_output=args.ascii,
            apply_registration=args.apply_registration,
            include_confidence=args.include_confidence,
            overwrite=args.overwrite,
        )
        if args.write_manifest:
            _write_manifest_json(
                gsmap.manifest,
                manifest_path,
                args.overwrite,
            )
    except (GsmapFormatError, OSError, OverflowError, struct.error, ValueError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1

    print(f"Converted: {input_path}")
    print(f"       to: {output_path}")
    print(f"   points: {gsmap.point_count} in {len(gsmap.chunks)} chunks")
    print(f"   format: {'ASCII' if args.ascii else 'binary little-endian'} PLY")
    print(f"coordinates: {'registered' if args.apply_registration else 'raw lingbot_world'}")
    if args.apply_registration and registration_confirmed is False:
        print("warning: the stored registration is not confirmed", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
