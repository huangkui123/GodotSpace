"""One bounded, local RGB/CAD job for the Sky UI (no server, depth or clicks).

The existing SIFT/PnP backend is experimental. Results are candidates for an
explicit user preview/application, never evidence of physical accuracy.
"""
from __future__ import annotations

import argparse
import base64
import json
import os
from pathlib import Path
import sys

import cv2
import numpy as np

from geometry import load_mesh, sha256
from rgb_pose import estimate

MAX_REQUEST = 36 * 1024 * 1024


def decode_frame(frame: dict) -> tuple[np.ndarray, np.ndarray, np.ndarray]:
    data = base64.b64decode(frame["jpeg_base64"], validate=True)
    if not 0 < len(data) <= 8 * 1024 * 1024:
        raise ValueError("JPEG exceeds the frame limit")
    width, height = frame["width"], frame["height"]
    if (not isinstance(width, int) or not isinstance(height, int)
            or not 16 <= width <= 4096 or not 16 <= height <= 4096
            or width * height > 8_000_000):
        raise ValueError("Invalid image dimensions")
    # Check dimensions before the decoder allocates an image.
    from PIL import Image
    import io
    with Image.open(io.BytesIO(data)) as header:
        if header.format != "JPEG" or header.size != (width, height):
            raise ValueError("JPEG dimensions differ from camera intrinsics")
    image = cv2.imdecode(np.frombuffer(data, np.uint8), cv2.IMREAD_COLOR)
    if image is None or image.shape[:2] != (height, width):
        raise ValueError("Invalid JPEG")
    k = np.asarray(frame["K"], dtype=float)
    if (k.shape != (3, 3) or not np.isfinite(k).all()
            or min(k[0, 0], k[1, 1]) <= 0
            or not np.allclose(k[2], [0, 0, 1])
            or not np.allclose([k[0, 1], k[1, 0]], 0)
            or not 0 <= k[0, 2] < width or not 0 <= k[1, 2] < height):
        raise ValueError("Invalid camera matrix")
    if frame.get("rectified") is not True:
        raise ValueError("Only rectified monocular images are supported")
    return image, k, np.zeros(5)


def load_assets(artifacts: Path) -> tuple[dict, dict, object]:
    bank = artifacts / "templates"
    assembly = artifacts / "assembly"
    manifest = json.loads((bank / "templates.json").read_text(encoding="utf-8"))
    report = json.loads((assembly / "assembly_report.json").read_text(encoding="utf-8"))
    model = assembly / "printed_assembly.ply"
    digest = sha256(model)
    if (digest != manifest["model_sha256"] or digest != report["model_sha256"]
            or report["coordinate_system"] != "godot_frame_mesh_local_right_handed_y_up"
            or manifest["model_units"] != "meters"):
        raise ValueError("CAD, alignment report and feature bank do not match; rebuild artifacts")
    scale = float(report["print_scale"])
    if not np.isfinite(scale) or scale <= 0:
        raise ValueError("Invalid template scale")
    return manifest, report, load_mesh(model)


def overlay(image, points, pose, k):
    out = image.copy()
    camera_points = points @ pose[:3, :3].T + pose[:3, 3]
    visible = camera_points[:, 2] > 0.02
    camera_points = camera_points[visible]
    uv = camera_points @ k.T
    uv = uv[:, :2] / uv[:, 2:]
    for x, y in uv:
        if 0 <= x < out.shape[1] and 0 <= y < out.shape[0]:
            cv2.circle(out, (round(x), round(y)), 1, (80, 230, 120), -1)
    ok, data = cv2.imencode(".jpg", out, [cv2.IMWRITE_JPEG_QUALITY, 85])
    if not ok:
        raise ValueError("Cannot encode overlay")
    return base64.b64encode(data).decode("ascii")


def run_job(request: dict, artifacts: Path) -> dict:
    if request.get("schema_version") != 1 or not isinstance(request.get("request_id"), str):
        raise ValueError("Invalid job schema")
    mode = request.get("mode")
    scale = float(request["physical_scale"])
    if mode not in ("live", "demo") or not np.isfinite(scale) or not 0.05 <= scale <= 2:
        raise ValueError("Invalid mode or physical scale")
    manifest, report, mesh = load_assets(artifacts)
    ratio = scale / float(report["print_scale"])
    points = np.asarray(mesh.vertices)[::max(1, len(mesh.vertices) // 4000)][:4000] * ratio
    result = {"schema_version": 1, "request_id": request["request_id"], "mode": mode,
              "physical_scale": scale, "model_sha256": manifest["model_sha256"],
              "backend": manifest["backend"], "real_camera_validated": False,
              "automatic_application_allowed": False,
              "coordinate_system": "opencv_camera_x_right_y_down_z_forward",
              "model_coordinates": report["coordinate_system"], "units": "meters",
              "model_points": points.tolist(), "model_extents_m": (mesh.extents * ratio).tolist(), "frames": []}
    frames = request.get("frames", [])
    if mode == "demo":
        # A held-out view, not an image retrieved from the template bank.
        from render_model import camera_pose, render
        k = np.array([[720, 0, 320], [0, 710, 320], [0, 0, 1]], dtype=float)
        truth = camera_pose(mesh.bounds.mean(0), mesh.extents.max() * 1.8, 95, 10)
        rgb, xyz = render(mesh, truth, k, background=100, light=(0.2, -0.6, -1))
        background = ~np.isfinite(xyz).all(axis=-1)
        gradient = np.broadcast_to(np.linspace(70, 130, 640), (640, 640))
        rgb[background] = np.repeat(gradient[background, None], 3, axis=1).astype(np.uint8)
        image = cv2.cvtColor(cv2.GaussianBlur(rgb, (3, 3), 0.5), cv2.COLOR_RGB2BGR)
        inputs = [("demo", image, k, np.zeros(5))]
    else:
        if not isinstance(frames, list) or len(frames) != 3:
            raise ValueError("Live recognition requires three distinct frames")
        identifiers = [str(frame["capture_id"]) for frame in frames]
        if len(set(identifiers)) != 3:
            raise ValueError("Repeated camera frames cannot establish consistency")
        inputs = [(identifier, *decode_frame(frame)) for identifier, frame in zip(identifiers, frames)]
    last_pose = None
    for identifier, image, k, distortion in inputs:
        prediction = estimate(image, k, distortion, artifacts / "templates")
        row = {"capture_id": identifier, "status": prediction["status"]}
        if prediction["status"] == "candidate":
            candidate = prediction["candidates"][0].copy()
            pose = np.asarray(candidate["camera_from_model"], dtype=float)
            pose[:3, 3] *= ratio
            candidate["camera_from_model"] = pose.tolist()
            row.update(candidate)
            last_pose = pose
        else:
            last_pose = None
        result["frames"].append(row)
    result["status"] = "candidate" if all(row["status"] == "candidate" for row in result["frames"]) else "rejected"
    # Always show the actual processed frame, including failures, without fabricating corners.
    result["overlay_jpeg_base64"] = overlay(image, points if last_pose is not None else points[:0],
                                            last_pose if last_pose is not None else np.eye(4), k)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--request", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--artifacts", type=Path, required=True)
    args = parser.parse_args()
    cv2.setNumThreads(2)
    request = {}
    try:
        if args.request.stat().st_size > MAX_REQUEST:
            raise ValueError("Job request too large")
        request = json.loads(args.request.read_text(encoding="utf-8"))
        result = run_job(request, args.artifacts)
    except Exception as error:
        result = {"schema_version": 1, "request_id": request.get("request_id", ""),
                  "status": "error", "error": str(error)[:500]}
    temporary = args.output.with_suffix(".tmp")
    temporary.write_text(json.dumps(result, allow_nan=False), encoding="utf-8")
    os.replace(temporary, args.output)
    return 1 if result["status"] == "error" else 0


if __name__ == "__main__":
    sys.exit(main())
