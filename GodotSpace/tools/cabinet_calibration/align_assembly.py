"""Align decoded Magics assembly geometry to the authored Godot cabinet."""
from __future__ import annotations

import argparse
import json
from pathlib import Path

import numpy as np
import trimesh

from geometry import load_mesh, register, sample_surface, sha256
from render_model import comparison


def align(source_path: Path, virtual_dir: Path, output: Path, scale: float) -> dict:
    if not np.isfinite(scale) or scale <= 0:
        raise ValueError("Print scale must be finite and positive")
    source = load_mesh(source_path)
    source.apply_scale(scale)
    virtual_manifest = json.loads((virtual_dir / "virtual_cabinet.json").read_text(encoding="utf-8"))
    target = trimesh.util.concatenate([
        load_mesh(virtual_dir / part["file"]) for part in virtual_manifest["parts"]])
    target.apply_scale(scale)
    candidates = register(sample_surface(source, 18000, 301),
                          sample_surface(target, 36000, 302))
    transform = np.array(candidates[0]["source_m_to_reference_m"])
    source.apply_transform(transform)
    output.mkdir(parents=True, exist_ok=True)
    source.export(output / "printed_assembly.ply")
    target.export(output / "virtual_assembly.obj")
    report = {
        "schema_version": 1,
        "status": "candidate_not_a_verified_physical_calibration",
        "source_sha256": sha256(source_path),
        "print_scale": scale,
        "physical_scale_verified": False,
        "coordinate_system": "godot_frame_mesh_local_right_handed_y_up",
        "units": "meters_at_assumed_print_scale",
        "candidates": candidates,
        "model_file": "printed_assembly.ply",
        "model_sha256": sha256(output / "printed_assembly.ply"),
        "geometry_alignment_verified": False,
        "limitations": [
            "Raw Magics mesh placement only; encrypted metadata not interpreted.",
            "Reference includes authored rest pose; printed moving parts may have another pose.",
            "Sampled mesh distances are not real-camera pose accuracy.",
        ],
    }
    (output / "assembly_report.json").write_text(
        json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
    comparison(source, target, output / "comparison.png")
    return report


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    parser.add_argument("--virtual-dir", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--print-scale", type=float, required=True)
    args = parser.parse_args()
    report = align(args.source, args.virtual_dir, args.output, args.print_scale)
    print(json.dumps(report, ensure_ascii=False, indent=2))
