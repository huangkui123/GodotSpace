"""One bounded, local RGB/CAD job for the Sky UI (no server, depth or clicks).

The existing SIFT/PnP backend is experimental. Results are candidates for an
explicit user preview/application, never evidence of physical accuracy.
"""
from __future__ import annotations

import argparse
import base64
import json
import hashlib
import os
from pathlib import Path
import sys

import cv2
import numpy as np

from geometry import load_mesh, sha256
from rgb_pose import estimate
import cuboid_pose
import cuboid_multiview
from cuboid_faces import face_proposals, pose_seeds
import camera_timing
from diagnostic_capture import save_case

MAX_REQUEST = 36 * 1024 * 1024
MAX_FRAMES = 16


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
    # Bound all per-frame previews together, even with full resolution input.
    if max(out.shape[:2]) > 960:
        factor = 960 / max(out.shape[:2])
        out = cv2.resize(out, (round(out.shape[1] * factor), round(out.shape[0] * factor)),
                         interpolation=cv2.INTER_AREA)
    ok, data = cv2.imencode(".jpg", out, [cv2.IMWRITE_JPEG_QUALITY, 85])
    # 17 previews (16 candidates + last frame), base64 and pose data must fit
    # inside the client's 16 MiB result-file limit even for noisy images.
    while ok and len(data) > 512 * 1024:
        out = cv2.resize(out, (max(1, out.shape[1] * 3 // 4), max(1, out.shape[0] * 3 // 4)),
                         interpolation=cv2.INTER_AREA)
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
    kind = request.get("model_kind", "cad")
    if kind not in ("cad", "cuboid"):
        raise ValueError("Unknown model kind")
    size = None
    if kind == "cuboid":
        size = cuboid_pose.dimensions(request.get("dimensions_m"))
        if scale != 1:
            raise ValueError("Custom dimensions are already physical metres; scale must be one")
        mesh = cuboid_pose.mesh_for(size)
        manifest = {"backend": "experimental_upright_cuboid_edges_pnp",
                    "model_sha256": hashlib.sha256(size.astype('<f8').tobytes()).hexdigest()}
        report = {"coordinate_system": cuboid_pose.COORDINATES, "print_scale": 1}
        points = cuboid_pose.preview_points(size)
    else:
        manifest, report, mesh = load_assets(artifacts)
        points = np.asarray(mesh.vertices)[::max(1, len(mesh.vertices) // 4000)][:4000]
    ratio = scale / float(report["print_scale"])
    points = points * ratio
    result = {"schema_version": 1, "request_id": request["request_id"], "mode": mode,
              "model_kind": kind,
              "physical_scale": scale, "model_sha256": manifest["model_sha256"],
              "backend": manifest["backend"], "real_camera_validated": False,
              "automatic_application_allowed": False,
              "coordinate_system": "opencv_camera_x_right_y_down_z_forward",
              "model_coordinates": report["coordinate_system"], "units": "meters",
              "model_points": points.tolist(), "model_extents_m": (mesh.extents * ratio).tolist(), "frames": []}
    if kind == "cuboid":
        result["dimensions_m"] = size.tolist()
    multiview = mode == 'live' and request.get('multiview') is True
    result['multiview'] = multiview
    result['pose_timing'] = request.get('pose_timing', 'unspecified')
    if multiview and kind == 'cuboid':
        result['backend'] = 'experimental_multiview_upright_cuboid_edges'
    views, seeds, view_indices = [], [], []
    timing, corrected_cameras = None, None
    frames = request.get("frames", [])
    if mode == "demo":
        # A held-out view, not an image retrieved from the template bank.
        from render_model import camera_pose, render
        k = np.array([[720, 0, 320], [0, 710, 320], [0, 0, 1]], dtype=float)
        truth = camera_pose(mesh.bounds.mean(0), mesh.extents.max() * (2.4 if kind == "cuboid" else 1.8),
                            35 if kind == "cuboid" else 95, 18 if kind == "cuboid" else 10)
        rgb, xyz = render(mesh, truth, k, background=35 if kind == "cuboid" else 100,
                          light=(-.3, -.7, -1) if kind == "cuboid" else (0.2, -0.6, -1))
        background = ~np.isfinite(xyz).all(axis=-1)
        gradient = np.broadcast_to(np.linspace(25, 45, 640) if kind == "cuboid"
                                   else np.linspace(70, 130, 640), (640, 640))
        rgb[background] = np.repeat(gradient[background, None], 3, axis=1).astype(np.uint8)
        image = cv2.cvtColor(cv2.GaussianBlur(rgb, (3, 3), 0.5), cv2.COLOR_RGB2BGR)
        inputs = [("demo", image, k, np.zeros(5), truth[:3, 1])]
    else:
        if not isinstance(frames, list) or not 3 <= len(frames) <= MAX_FRAMES:
            raise ValueError("Live recognition requires 3..16 distinct frames")
        if sum(len(frame.get("jpeg_base64", "")) for frame in frames) > 32 * 1024 * 1024:
            raise ValueError("Capture sequence exceeds the image budget")
        identifiers = [str(frame["capture_id"]) for frame in frames]
        if len(set(identifiers)) != len(frames):
            raise ValueError("Repeated camera frames cannot establish consistency")
        if multiview and request.get('pose_timing') == 'interpolated_arrival_estimate':
            timing, corrected_cameras = camera_timing.check(frames, decode_frame)
            result['camera_timing'] = timing
        # Decode one frame at a time: a sequence must not retain 16 full images.
        inputs = ((identifier, *decode_frame(frame), frame.get("camera_up"))
                  for identifier, frame in zip(identifiers, frames))
    for frame_index, (identifier, image, k, distortion, camera_up) in enumerate(inputs):
        if timing is not None and timing['status'] == 'verified':
            camera_up = corrected_cameras[frame_index][:3, :3].T @ np.array([0., 1., 0.])
        prediction = (cuboid_pose.estimate_cuboid(image, k, size, camera_up) if kind == "cuboid"
                      else estimate(image, k, distortion, artifacts / "templates"))
        if timing is not None and (timing['status'] != 'verified' or frame_index not in timing['support_indices']):
            # Older clients also consume per-frame CAD poses. Never leave an
            # unverified frame marked candidate merely because its pixels fit.
            prediction = {'status': 'not_found', 'candidates': []}
        row = {"capture_id": identifier, "status": prediction["status"]}
        if prediction["status"] == "candidate":
            candidate = prediction["candidates"][0].copy()
            pose = np.asarray(candidate["camera_from_model"], dtype=float)
            pose[:3, 3] *= ratio
            candidate["camera_from_model"] = pose.tolist()
            row.update(candidate)
            row["overlay_jpeg_base64"] = overlay(image, points, pose, k)
        result["frames"].append(row)
        if multiview and kind == 'cuboid':
            proposals = face_proposals(image)
            hypotheses = pose_seeds(image, k, size, camera_up, proposals)
            row['face_proposals'] = len(proposals)
            row['pose_hypotheses'] = len(hypotheses)
            if timing is not None and (timing['status'] != 'verified' or frame_index not in timing['support_indices']):
                continue
            world_camera = (corrected_cameras[frame_index] if corrected_cameras is not None
                            else cuboid_multiview.rigid(frames[frame_index].get('world_from_camera')))
            views.append(cuboid_multiview.prepare(image, k, world_camera))
            view_indices.append(frame_index)
            seeds.extend(world_camera @ seed for seed in hypotheses)
            if prediction['status'] == 'candidate':
                seeds.append(world_camera @ pose)
    counts = {status: sum(row["status"] == status for row in result["frames"])
              for status in ("candidate", "not_found", "ambiguous")}
    result["frame_counts"] = counts
    # This is only a proposal. The client must check consensus in world space
    # using its local capture poses before enabling preview/application.
    result["status"] = "candidate" if counts["candidate"] >= (1 if mode == "demo" else 3) else "rejected"
    # Rejection shows the actual last frame without an unaccepted projection.
    # Success uses a per-frame overlay selected from the client's stable group.
    result["overlay_jpeg_base64"] = overlay(image, points[:0], np.eye(4), k)
    if timing is not None and timing['status'] != 'verified':
        result['status'] = 'rejected'
        result['multiview_fit'] = {'status': 'rejected', 'reason': timing['reason']}
        return result
    if multiview and kind == 'cuboid':
        fitted = cuboid_multiview.fit(views, seeds, size)
        fitted['input_frame_indices'] = view_indices
        result['multiview_fit'] = fitted
        result['status'] = fitted['status']
        if fitted['status'] == 'candidate':
            fitted['support_indices'] = [view_indices[i] for i in fitted['support_indices']]
            world_pose = np.asarray(fitted['world_from_model'])
            for index in fitted['support_indices']:
                image, k, _ = decode_frame(frames[index])
                pose = np.linalg.inv(views[view_indices.index(index)]['camera']) @ world_pose
                result['frames'][index]['overlay_jpeg_base64'] = overlay(image, points, pose, k)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    inputs = parser.add_mutually_exclusive_group(required=True)
    inputs.add_argument("--request", type=Path)
    inputs.add_argument("--replay", type=Path, help="Replay a locally saved scan without recapturing")
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--artifacts", type=Path, required=True)
    parser.add_argument("--diagnostic", type=Path, help="Replace the last local live scan (includes images)")
    args = parser.parse_args()
    cv2.setNumThreads(2)
    request = {}
    try:
        source = args.replay or args.request
        if source.stat().st_size > (64 * 1024 * 1024 if args.replay else MAX_REQUEST):
            raise ValueError("Job request too large")
        loaded = json.loads(source.read_text(encoding="utf-8"))
        if args.replay:
            loaded = loaded['request']
        if not isinstance(loaded, dict):
            raise ValueError('Expected a request object')
        request = loaded
        # Capture before recognition too, so a timeout still leaves the inputs.
        if not args.replay:
            save_case(args.diagnostic, request, {'status': 'processing', 'request_id': request.get('request_id')})
        result = run_job(request, args.artifacts)
    except Exception as error:
        result = {"schema_version": 1, "request_id": request.get("request_id", ""),
                  "status": "error", "error": str(error)[:500]}
    if args.diagnostic and not args.replay and request.get('mode') == 'live':
        saved = save_case(args.diagnostic, request, result)
        result['diagnostic_path'] = saved
        result['diagnostic_saved'] = saved is not None
    temporary = args.output.with_suffix(".tmp")
    temporary.write_text(json.dumps(result, allow_nan=False), encoding="utf-8")
    os.replace(temporary, args.output)
    return 1 if result["status"] == "error" else 0


if __name__ == "__main__":
    sys.exit(main())
