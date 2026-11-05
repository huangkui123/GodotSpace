"""Held-out RGB views with known ground truth; never a substitute for PICO QA."""
import argparse
import json
from pathlib import Path

import cv2
import numpy as np
from scipy.spatial.transform import Rotation

from geometry import load_mesh, sha256
from render_model import camera_pose, render
from rgb_pose import estimate, write_overlay


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--model", type=Path, required=True)
    parser.add_argument("--templates", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    manifest = json.loads((args.templates / "templates.json").read_text(encoding="utf-8"))
    if sha256(args.model) != manifest["model_sha256"]:
        raise ValueError("Wrong template model")
    mesh = load_mesh(args.model)
    args.output.mkdir(parents=True, exist_ok=True)
    k = np.array([[720, 0, 320], [0, 710, 320], [0, 0, 1]], dtype=float)
    distortion = np.zeros(5)
    camera = {"width": 640, "height": 640, "K": k.tolist(), "distortion": distortion.tolist(),
              "source": "synthetic_ground_truth_not_pico_calibration"}
    (args.output / "camera.json").write_text(json.dumps(camera, indent=2), encoding="utf-8")
    rng = np.random.default_rng(47)
    rows = []
    for index, (yaw, elevation) in enumerate(((65, 15), (95, 10), (245, 20))):
        truth = camera_pose(mesh.bounds.mean(0), mesh.extents.max() * 1.8, yaw, elevation)
        rgb, xyz = render(mesh, truth, k, background=100, light=(0.2, -0.6, -1))
        background = ~np.isfinite(xyz).all(axis=-1)
        gradient = np.broadcast_to(np.linspace(70, 130, 640), (640, 640))
        rgb[background] = np.repeat(gradient[background, None], 3, axis=1).astype(np.uint8)
        image = np.clip(rgb.astype(float) + rng.normal(0, 1.5, rgb.shape), 0, 255).astype(np.uint8)
        image = cv2.cvtColor(cv2.GaussianBlur(image, (3, 3), 0.5), cv2.COLOR_RGB2BGR)
        cv2.imwrite(str(args.output / f"held_out_{index}.png"), image)
        result = estimate(image, k, distortion, args.templates)
        row = {"yaw": yaw, "elevation": elevation, "status": result["status"],
               "passed": False, "pose": result}
        if result["candidates"]:
            prediction = np.array(result["candidates"][0]["camera_from_model"])
            row["translation_error_m"] = float(np.linalg.norm(prediction[:3, 3] - truth[:3, 3]))
            row["rotation_error_deg"] = float(np.rad2deg(Rotation.from_matrix(
                truth[:3, :3].T @ prediction[:3, :3]).magnitude()))
            row["passed"] = (result["status"] == "candidate"
                             and row["translation_error_m"] < 0.01
                             and row["rotation_error_deg"] < 5)
        write_overlay(image, result, mesh, k, distortion, args.output / f"overlay_{index}.png")
        rows.append(row)
        print(json.dumps({key: value for key, value in row.items() if key != "pose"}), flush=True)
    summary = {"domain": "synthetic_only", "real_camera_validated": False,
               "successes": sum(row["passed"] for row in rows), "total": len(rows),
               "model_sha256": sha256(args.model), "cases": rows}
    (args.output / "validation.json").write_text(json.dumps(summary, indent=2), encoding="utf-8")
    print(f"Synthetic accepted poses: {summary['successes']}/{summary['total']}", flush=True)
    # A toolchain that cannot solve any held-out view is not a working baseline.
    if summary["successes"] == 0:
        raise SystemExit(1)


if __name__ == "__main__":
    main()
