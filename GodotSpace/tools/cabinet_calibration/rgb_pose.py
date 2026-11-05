"""Experimental markerless RGB baseline: synthetic CAD features -> RANSAC PnP.

No real depth, tags, manual image points or pretrained weights are used.
This baseline must be measured on PICO captures before runtime auto-application.
Untextured, repeated, occluded, or mismatched geometry can legitimately return
not_found/ambiguous. A good synthetic score is NOT real-world validation.
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path
import time

import cv2
import numpy as np
from scipy.spatial.transform import Rotation

from geometry import load_mesh, sha256
from render_model import camera_pose, render


def load_camera(path: Path, image_shape: tuple[int, ...]) -> tuple[np.ndarray, np.ndarray]:
    value = json.loads(path.read_text(encoding="utf-8"))
    if value.get("width") != image_shape[1] or value.get("height") != image_shape[0]:
        raise ValueError("Image resolution differs from camera calibration; do not silently resize K")
    matrix = np.asarray(value["K"], dtype=float)
    if "distortion" not in value:
        raise ValueError("Distortion must be explicit; zero is valid only for a verified rectified image")
    distortion = np.asarray(value["distortion"], dtype=float).reshape(-1)
    if (matrix.shape != (3, 3) or not np.isfinite(matrix).all()
            or min(matrix[0, 0], matrix[1, 1]) <= 0
            or not np.allclose(matrix[2], [0, 0, 1])
            or not np.allclose([matrix[0, 1], matrix[1, 0]], 0)
            or distortion.size not in (4, 5, 8, 12, 14)
            or not np.isfinite(distortion).all()):
        raise ValueError("Invalid camera intrinsics or distortion")
    return matrix, distortion


def build_templates(model_path: Path, output: Path, yaw_step: int = 15) -> dict:
    if yaw_step < 10 or yaw_step > 90 or 360 % yaw_step:
        raise ValueError("yaw_step must divide 360 and be in 10..90")
    mesh = load_mesh(model_path)
    if len(mesh.faces) > 15000000:
        raise ValueError("Mesh exceeds offline reference triangle budget")
    output.mkdir(parents=True, exist_ok=True)
    center = mesh.bounds.mean(axis=0)
    distance = float(mesh.extents.max() * 1.6)
    matrix = np.array([[650, 0, 320], [0, 650, 320], [0, 0, 1]], dtype=float)
    detector = cv2.SIFT_create(nfeatures=1600, contrastThreshold=0.015)
    rows = []
    for elevation in (0, 15, 30):
        for yaw in range(0, 360, yaw_step):
            pose = camera_pose(center, distance, yaw, elevation)
            rgb, xyz = render(mesh, pose, matrix)
            keypoints, descriptors = detector.detectAndCompute(
                cv2.cvtColor(rgb, cv2.COLOR_RGB2GRAY), None)
            points_3d, features = [], []
            if descriptors is not None:
                for keypoint, descriptor in zip(keypoints, descriptors):
                    x, y = np.rint(keypoint.pt).astype(int)
                    if not (0 <= x < 640 and 0 <= y < 640) or not np.isfinite(xyz[y, x]).all():
                        continue
                    points_3d.append(xyz[y, x])
                    features.append(descriptor)
            if len(points_3d) < 10:
                continue
            name = f"view_{yaw:03d}_{elevation:02d}"
            np.savez_compressed(output / (name + ".npz"),
                                points=np.asarray(points_3d, dtype=np.float32),
                                descriptors=np.asarray(features, dtype=np.float32))
            cv2.imwrite(str(output / (name + ".png")), cv2.cvtColor(rgb, cv2.COLOR_RGB2BGR))
            rows.append({"file": name + ".npz", "yaw": yaw, "elevation": elevation,
                         "features": len(features)})
            print(f"template {name}: {len(features)} features", flush=True)
    if not rows:
        raise ValueError("No usable synthetic features; this model needs another RGB pose backend")
    manifest = {"schema_version": 1, "backend": "experimental_synthetic_sift_pnp",
                "model_sha256": sha256(model_path),
                "model_units": "meters", "real_camera_validated": False, "templates": rows}
    (output / "templates.json").write_text(json.dumps(manifest, indent=2), encoding="utf-8")
    return manifest


def fit_correspondences(points: np.ndarray, pixels: np.ndarray, matrix: np.ndarray,
                        distortion: np.ndarray) -> dict | None:
    if (points.ndim != 2 or points.shape[1] != 3
            or pixels.shape != (len(points), 2) or len(points) < 10
            or not np.isfinite(points).all() or not np.isfinite(pixels).all()):
        return None
    # Do not let repeated descriptors vote several times for the same model point.
    _, unique = np.unique(np.round(points, 4), axis=0, return_index=True)
    points = np.ascontiguousarray(points[unique], dtype=np.float64)
    pixels = np.ascontiguousarray(pixels[unique], dtype=np.float64)
    if len(points) < 10:
        return None
    cv2.setRNGSeed(42)
    success, rvec, tvec, inliers = cv2.solvePnPRansac(
        points, pixels, matrix, distortion, iterationsCount=300,
        reprojectionError=3.0, confidence=0.999, flags=cv2.SOLVEPNP_EPNP)
    if not success or inliers is None or len(inliers) < 10:
        return None
    indices = inliers.ravel()
    if len(indices) / len(points) < 0.35:
        return None
    rvec, tvec = cv2.solvePnPRefineLM(points[indices], pixels[indices], matrix, distortion, rvec, tvec)
    rotation = cv2.Rodrigues(rvec)[0]
    camera_points = points[indices] @ rotation.T + tvec.ravel()
    if not np.isfinite(camera_points).all() or camera_points[:, 2].min() <= 0.02:
        return None
    projected = cv2.projectPoints(points[indices], rvec, tvec, matrix, distortion)[0].reshape(-1, 2)
    rms = float(np.sqrt(np.mean(np.sum((projected - pixels[indices]) ** 2, axis=1))))
    spatial_spread = np.linalg.svd(points[indices] - points[indices].mean(0), compute_uv=False)
    # At least a two-dimensional patch; a line of repeated holes is insufficient.
    if rms > 2.5 or spatial_spread[1] / np.sqrt(len(indices)) < 0.015:
        return None
    hull_area = cv2.contourArea(cv2.convexHull(pixels[indices].astype(np.float32)))
    if hull_area < 400:
        return None
    transform = np.eye(4)
    transform[:3, :3] = rotation
    transform[:3, 3] = tvec.ravel()
    return {"camera_from_model": transform.tolist(), "inliers": len(indices),
            "matches": len(points), "reprojection_rms_px": rms,
            "inlier_object_span_m": np.ptp(points[indices], axis=0).tolist(),
            "image_hull_area_px2": hull_area,
            "score": float(len(indices) / (1 + rms))}


def estimate(image: np.ndarray, matrix: np.ndarray, distortion: np.ndarray, bank: Path) -> dict:
    started = time.monotonic()
    manifest = json.loads((bank / "templates.json").read_text(encoding="utf-8"))
    detector = cv2.SIFT_create(nfeatures=3000, contrastThreshold=0.015)
    keypoints, descriptors = detector.detectAndCompute(cv2.cvtColor(image, cv2.COLOR_BGR2GRAY), None)
    result = {"schema_version": 1, "backend": manifest["backend"],
              "model_sha256": manifest["model_sha256"],
              "coordinate_system": "opencv_camera_x_right_y_down_z_forward",
              "units": "meters", "status": "not_found", "runtime_application_allowed": False,
              "real_camera_validated": False, "candidates": []}
    if descriptors is None or len(keypoints) < 10:
        return result
    matcher = cv2.BFMatcher(cv2.NORM_L2)
    candidates = []
    for entry in manifest["templates"]:
        with np.load(bank / entry["file"], allow_pickle=False) as data:
            matches = matcher.knnMatch(data["descriptors"], descriptors, k=2)
            selected = [pair[0] for pair in matches
                        if len(pair) == 2 and pair[0].distance < 0.72 * pair[1].distance]
            # One observation per image feature.
            selected.sort(key=lambda match: match.distance)
            by_image = {}
            for match in selected:
                by_image.setdefault(match.trainIdx, match)
            selected = list(by_image.values())
            if len(selected) < 10:
                continue
            points = data["points"][[match.queryIdx for match in selected]]
            pixels = np.array([keypoints[match.trainIdx].pt for match in selected])
            pose = fit_correspondences(points, pixels, matrix, distortion)
            if pose is not None:
                pose["template"] = entry["file"]
                candidates.append(pose)
    candidates.sort(key=lambda item: item["score"], reverse=True)
    if candidates:
        best = candidates[0]
        result["status"] = "candidate"
        best_transform = np.array(best["camera_from_model"])
        for other in candidates[1:]:
            other_transform = np.array(other["camera_from_model"])
            angular = Rotation.from_matrix(
                best_transform[:3, :3].T @ other_transform[:3, :3]).magnitude()
            translation = np.linalg.norm(best_transform[:3, 3] - other_transform[:3, 3])
            if other["score"] >= best["score"] * 0.75 and (angular > np.deg2rad(10) or translation > 0.03):
                result["status"] = "ambiguous"
                break
        result["candidates"] = candidates[:8]
    result["elapsed_seconds"] = time.monotonic() - started
    return result


def write_overlay(image: np.ndarray, result: dict, mesh, matrix: np.ndarray,
                  distortion: np.ndarray, path: Path) -> None:
    overlay = image.copy()
    if result["candidates"]:
        transform = np.array(result["candidates"][0]["camera_from_model"])
        rvec = cv2.Rodrigues(transform[:3, :3])[0]
        points = np.asarray(mesh.vertices)
        z = (points @ transform[:3, :3].T + transform[:3, 3])[:, 2]
        projected = cv2.projectPoints(points, rvec, transform[:3, 3], matrix, distortion)[0].reshape(-1, 2)
        for index in range(0, len(points), max(1, len(points) // 1800)):
            x, y = projected[index]
            if z[index] > 0.02 and 0 <= x < image.shape[1] and 0 <= y < image.shape[0]:
                cv2.circle(overlay, (round(x), round(y)), 1, (0, 220, 255), -1)
    cv2.putText(overlay, result["status"] + " / UNVALIDATED RGB BASELINE",
                (12, 28), cv2.FONT_HERSHEY_SIMPLEX, 0.65, (0, 140, 255), 2)
    cv2.imwrite(str(path), overlay)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    build = sub.add_parser("build")
    build.add_argument("--model", type=Path, required=True)
    build.add_argument("--output", type=Path, required=True)
    build.add_argument("--yaw-step", type=int, default=15)
    infer = sub.add_parser("infer")
    infer.add_argument("--image", type=Path, required=True)
    infer.add_argument("--camera", type=Path, required=True)
    infer.add_argument("--templates", type=Path, required=True)
    infer.add_argument("--model", type=Path, required=True)
    infer.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    if args.command == "build":
        build_templates(args.model, args.output, args.yaw_step)
        return
    image = cv2.imdecode(np.fromfile(args.image, dtype=np.uint8), cv2.IMREAD_COLOR)
    if image is None:
        parser.error("Cannot decode image")
    matrix, distortion = load_camera(args.camera, image.shape)
    manifest = json.loads((args.templates / "templates.json").read_text(encoding="utf-8"))
    if sha256(args.model) != manifest["model_sha256"]:
        parser.error("Template bank belongs to another mesh")
    result = estimate(image, matrix, distortion, args.templates)
    args.output.mkdir(parents=True, exist_ok=True)
    (args.output / "pose.json").write_text(json.dumps(result, indent=2), encoding="utf-8")
    write_overlay(image, result, load_mesh(args.model), matrix, distortion, args.output / "overlay.png")
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()
