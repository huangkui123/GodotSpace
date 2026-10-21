"""Inspect extracted print meshes and register a fixed frame to Godot geometry.

No source files are modified. Unit and print scale are explicit hypotheses and
the output is a candidate calibration asset, never a verified physical anchor.
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path
import struct

import numpy as np

from geometry import load_mesh, register, sample_surface, sha256

STL_TRIANGLE = np.dtype([("normal", "<f4", (3,)), ("vertices", "<f4", (3, 3)),
                         ("attribute", "<u2")])


def inspect_stl(path: Path) -> dict:
    # mmap avoids allocating all 13 million triangles in the supplied archive.
    with path.open("rb") as stream:
        header = stream.read(84)
    if len(header) < 84:
        raise ValueError(f"Truncated STL: {path.name}")
    count = struct.unpack_from("<I", header, 80)[0]
    if path.stat().st_size == 84 + count * 50 and count > 0:
        records = np.memmap(path, dtype=STL_TRIANGLE, offset=84, mode="r", shape=(count,))
        vertices = records["vertices"]
        lower = vertices.min(axis=(0, 1)).astype(float)
        upper = vertices.max(axis=(0, 1)).astype(float)
        if not np.isfinite([lower, upper]).all():
            raise ValueError(f"Non-finite STL: {path.name}")
    else:
        mesh = load_mesh(path)
        lower, upper = mesh.bounds
        count = len(mesh.faces)
    return {"file": path.name, "sha256": sha256(path), "triangles": count,
            "bounds_min": lower.tolist(), "bounds_max": upper.tolist(),
            "extents_source_units": (upper - lower).tolist()}


def prepare(print_dir: Path, virtual_dir: Path, output: Path, units_to_m: float,
            print_scale: float, frame: Path | None = None, samples: int = 16000) -> dict:
    if not np.isfinite([units_to_m, print_scale]).all() or min(units_to_m, print_scale) <= 0:
        raise ValueError("Unit conversion and print scale must be finite and positive")
    paths = sorted(print_dir.rglob("*.stl"))
    if not paths:
        raise ValueError("No STL meshes found")
    inventory = [inspect_stl(path) for path in paths]
    # The largest bounding volume is only a candidate. Report the choice.
    selected = frame if frame is not None else paths[
        int(np.argmax([np.prod(row["extents_source_units"]) for row in inventory]))]
    source = load_mesh(selected)
    source.apply_scale(units_to_m)
    target = load_mesh(virtual_dir / "frame.obj")
    target.apply_scale(print_scale)
    candidates = register(sample_surface(source, samples, 101),
                          sample_surface(target, samples * 2, 202))
    transform = np.array(candidates[0]["source_m_to_reference_m"])
    aligned = source.copy()
    aligned.apply_transform(transform)
    # Retain geometry: aggressive reduction damages thin print surfaces. This
    # offline reference must not be loaded into the XR runtime as a display mesh.
    output.mkdir(parents=True, exist_ok=True)
    aligned.export(output / "printed_frame.ply")
    target.export(output / "virtual_frame.obj")
    report = {
        "schema_version": 1,
        "status": "candidate_requires_geometry_and_physical_validation",
        "unit_hypothesis": {"source_units_to_m": units_to_m,
                            "physical_to_virtual_size_ratio": print_scale,
                            "verified_against_physical_object": False},
        "frame_selection": "explicit" if frame is not None else "largest_bounding_volume_candidate",
        "frame_file": selected.name,
        "frame_sha256": sha256(selected),
        "virtual_frame_sha256": sha256(virtual_dir / "frame.obj"),
        "source_frame_extents_m": source.extents.tolist(),
        "virtual_frame_extents_at_print_scale_m": target.extents.tolist(),
        "coordinate_system": "godot_frame_mesh_local_right_handed_y_up",
        "transform_convention": "row_major_column_vectors_target_T_source",
        "sampling": {"source": samples, "target": samples * 2, "seeds": [101, 202]},
        "candidates": candidates,
        "offline_mesh": {"file": "printed_frame.ply", "triangles": len(aligned.faces),
                         "sha256": sha256(output / "printed_frame.ply"),
                         "note": "Fixed frame only; detached print parts are not yet assembled"},
        "inventory": inventory,
    }
    (output / "model_report.json").write_text(
        json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
    return report


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--print-dir", type=Path, required=True, help="Extracted STL directory")
    parser.add_argument("--virtual-dir", type=Path, required=True, help="export_cabinet.gd output")
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--source-units-to-m", type=float, required=True)
    parser.add_argument("--print-scale", type=float, required=True)
    parser.add_argument("--frame", type=Path, help="Override automatic fixed-frame candidate")
    parser.add_argument("--samples", type=int, default=16000)
    args = parser.parse_args()
    if not 1000 <= args.samples <= 100000:
        parser.error("--samples must be between 1000 and 100000")
    report = prepare(args.print_dir, args.virtual_dir, args.output, args.source_units_to_m,
                     args.print_scale, args.frame, args.samples)
    print(json.dumps({key: report[key] for key in
                      ["status", "frame_file", "source_frame_extents_m", "candidates"]},
                     ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
