"""Automatic upright cuboid pose from a closed silhouette and visible edges.

No manual points, CAD bank, learned weights or depth are needed. The six-point
silhouette must expose depth; a flat rectangle is deliberately insufficient.
An unmarked box has no semantic front/back: +Z is the width face toward the
camera. This convention is checked across the capture batch by the caller.
"""
from __future__ import annotations

from itertools import product

import cv2
import numpy as np

from render_model import camera_pose

COORDINATES = "cabinet_front_bottom_left_x_right_y_up_depth_negative_z"
DEFAULT_DIMENSIONS = (0.45, 1.21, 0.80)  # width, height, depth, metres
EDGES = ((0, 1), (1, 2), (2, 3), (3, 0), (4, 5), (5, 6), (6, 7),
         (7, 4), (0, 4), (1, 5), (2, 6), (3, 7))
FACES = ((0, 1, 2, 3), (4, 5, 6, 7), (0, 4, 5, 1),
         (3, 2, 6, 7), (0, 3, 7, 4), (1, 5, 6, 2))


def dimensions(value) -> np.ndarray:
    size = np.asarray(value, dtype=float)
    if size.shape != (3,) or not np.isfinite(size).all() or np.any(size < .05) or np.any(size > 20):
        raise ValueError("Cuboid width, height and depth must be in 0.05..20 metres")
    return size


def corners(size) -> np.ndarray:
    w, h, d = dimensions(size)
    return np.array([[0, h, 0], [w, h, 0], [w, 0, 0], [0, 0, 0],
                     [0, h, -d], [w, h, -d], [w, 0, -d], [0, 0, -d]], dtype=float)


def preview_points(size) -> np.ndarray:
    points = corners(size)
    return np.concatenate([np.linspace(points[a], points[b], 24) for a, b in EDGES])


def mesh_for(size):
    import trimesh
    w, h, d = dimensions(size)
    mesh = trimesh.creation.box(extents=[w, h, d])
    mesh.apply_translation([w / 2, h / 2, -d / 2])
    return mesh


def _project(points, pose, k):
    camera = points @ pose[:3, :3].T + pose[:3, 3]
    homogeneous = camera @ k.T
    return homogeneous[:, :2] / homogeneous[:, 2:], camera[:, 2]


def _silhouettes(points, k):
    center = points.mean(0)
    orders = set()
    for yaw, elevation in product((-135, -45, 45, 135), (-25, 25)):
        pose = camera_pose(center, np.ptp(points, axis=0).max() * 3, yaw, elevation)
        pixels, _ = _project(points, pose, k)
        order = tuple(cv2.convexHull(pixels.astype(np.float32), returnPoints=False).ravel())
        if len(order) == 6:
            orders.add(order)
    return sorted(orders)


def _polygons(gray, edges):
    # Multiple thresholds tolerate light or dark cabinets. All candidates must
    # subsequently explain the observed internal as well as silhouette edges.
    _, binary = cv2.threshold(gray, 0, 255, cv2.THRESH_BINARY + cv2.THRESH_OTSU)
    masks = [cv2.morphologyEx(edges, cv2.MORPH_CLOSE, np.ones((3, 3), np.uint8)), binary, 255 - binary]
    candidates = []
    height, width = gray.shape
    for mask in masks:
        contours, _ = cv2.findContours(mask, cv2.RETR_LIST, cv2.CHAIN_APPROX_NONE)
        for contour in sorted(contours, key=cv2.contourArea, reverse=True)[:30]:
            area = cv2.contourArea(contour)
            if not 1500 <= area <= width * height * .85:
                continue
            hull = cv2.convexHull(contour)
            if area / max(cv2.contourArea(hull), 1) < .94:
                continue
            polygon = None
            for fraction in (.003, .005, .008, .012):
                proposal = cv2.approxPolyDP(hull, fraction * cv2.arcLength(hull, True), True).reshape(-1, 2)
                if len(proposal) == 6:
                    polygon = proposal
                    break
            if polygon is None or np.any(polygon < 4) or np.any(polygon >= [width - 4, height - 4]):
                continue
            if min(np.linalg.norm(polygon - np.roll(polygon, 1, axis=0), axis=1)) < 12:
                continue
            polygon = cv2.convexHull(polygon.astype(np.float32)).reshape(-1, 2)
            # Intersect fitted contour lines instead of treating a staircase
            # endpoint from approxPolyDP as an exact image corner.
            lines = []
            samples = contour.reshape(-1, 2).astype(float)
            for a, b in zip(polygon, np.roll(polygon, -1, axis=0)):
                delta = b - a
                length = np.linalg.norm(delta)
                along = (samples - a) @ delta / length ** 2
                normal = np.array([-delta[1], delta[0]]) / length
                near = samples[(along > .12) & (along < .88) & (np.abs((samples - a) @ normal) < 2.5)]
                if len(near) < 6:
                    lines = []
                    break
                vx, vy, x, y = cv2.fitLine(near.astype(np.float32), cv2.DIST_L2, 0, .01, .01).ravel()
                lines.append((np.array([vx, vy]), np.array([x, y])))
            if len(lines) == 6:
                refined = []
                for i in range(6):
                    v, p = lines[i - 1]
                    u, q = lines[i]
                    matrix = np.column_stack((v, -u))
                    if abs(np.linalg.det(matrix)) < .08:
                        break
                    intersection = p + np.linalg.solve(matrix, q - p)[0] * v
                    if np.linalg.norm(intersection - polygon[i]) > 20:
                        break
                    refined.append(intersection)
                if len(refined) == 6:
                    polygon = np.asarray(refined, dtype=np.float32)
            if any(np.linalg.norm(polygon.mean(0) - other.mean(0)) < 8
                   and abs(cv2.contourArea(polygon) / cv2.contourArea(other) - 1) < .08 for other in candidates):
                continue
            candidates.append(polygon)
    return sorted(candidates, key=cv2.contourArea, reverse=True)[:12]


def _edge_support(points, pose, k, distance):
    eye = -pose[:3, :3].T @ pose[:3, 3]
    center = points.mean(0)
    visible_edges = set()
    for face in FACES:
        midpoint = points[list(face)].mean(0)
        if np.dot(midpoint - center, eye - midpoint) > 0:
            for a, b in zip(face, face[1:] + face[:1]):
                visible_edges.add(tuple(sorted((a, b))))
    coverages = []
    for a, b in visible_edges:
        pixels, depth = _project(np.linspace(points[a], points[b], 40)[3:-3], pose, k)
        xy = np.rint(pixels).astype(int)
        if np.any(depth <= .02) or np.any(xy < 0) or np.any(xy >= [distance.shape[1], distance.shape[0]]):
            return 0.0
        coverages.append(float(np.mean(distance[xy[:, 1], xy[:, 0]] < 3.5)))
    # A silhouette alone is insufficient; visible face junctions must agree.
    return min(coverages, default=0.0)


def estimate_cuboid(image, k, size, camera_up) -> dict:
    points = corners(size)
    up = np.asarray(camera_up, dtype=float)
    if up.shape != (3,) or not np.isfinite(up).all() or not .99 <= np.linalg.norm(up) <= 1.01:
        raise ValueError("Cuboid recognition needs a unit tracking-up vector in camera coordinates")
    gray = cv2.cvtColor(image, cv2.COLOR_BGR2GRAY)
    edges = cv2.Canny(cv2.GaussianBlur(gray, (3, 3), .6), 35, 100)
    # Pale cabinets against pale walls can have real edges below the fixed
    # threshold. Recover local contrast before edge extraction, while keeping
    # all geometric, gravity, junction-support and ambiguity checks unchanged.
    enhanced = cv2.createCLAHE(clipLimit=2.0, tileGridSize=(8, 8)).apply(gray)
    edges |= cv2.Canny(cv2.GaussianBlur(enhanced, (3, 3), .6), 35, 100)
    distance = cv2.distanceTransform(255 - edges, cv2.DIST_L2, 3)
    found = []
    for polygon in _polygons(gray, edges):
        for order in _silhouettes(points, k):
            object_points = np.ascontiguousarray(points[list(order)])
            for shift in range(6):
                pixels = np.ascontiguousarray(np.roll(polygon, shift, axis=0), dtype=float)
                ok, rvec, tvec = cv2.solvePnP(object_points, pixels, k, None, flags=cv2.SOLVEPNP_EPNP)
                if not ok:
                    continue
                rvec, tvec = cv2.solvePnPRefineLM(object_points, pixels, k, None, rvec, tvec)
                pose = np.eye(4)
                pose[:3, :3], pose[:3, 3] = cv2.Rodrigues(rvec)[0], tvec.ravel()
                if not np.isfinite(pose).all() or np.dot(pose[:3, 1], up) < np.cos(np.deg2rad(4)):
                    continue
                projected, depth = _project(points, pose, k)
                rms = float(np.sqrt(np.mean(np.sum((projected[list(order)] - pixels) ** 2, axis=1))))
                if depth.min() <= .02 or np.linalg.norm(pose[:3, 3]) > 30 or rms > 2.5:
                    continue
                projected_hull = cv2.convexHull(projected.astype(np.float32))
                intersection = cv2.intersectConvexConvex(projected_hull, polygon)[0]
                union = cv2.contourArea(projected_hull) + cv2.contourArea(polygon) - intersection
                iou = float(intersection / max(union, 1))
                if iou < .94:
                    continue
                support = _edge_support(points, pose, k, distance)
                if support < .8:
                    continue
                # Front/back are physically indistinguishable. Choose the
                # width face facing the camera, rotating about the box center.
                eye = -pose[:3, :3].T @ pose[:3, 3]
                center = points.mean(0)
                angle = np.pi if eye[2] < center[2] else 0.
                if abs(size[0] - size[2]) < 1e-6:
                    angle = round(np.arctan2(eye[0] - center[0], eye[2] - center[2]) / (np.pi / 2)) * (np.pi / 2)
                symmetry = np.eye(4)
                cosine, sine = np.cos(angle), np.sin(angle)
                symmetry[:3, :3] = [[cosine, 0, sine], [0, 1, 0], [-sine, 0, cosine]]
                symmetry[:3, 3] = center - symmetry[:3, :3] @ center
                pose = pose @ symmetry
                center_camera = pose[:3, :3] @ points.mean(0) + pose[:3, 3]
                if abs(np.dot(pose[:3, 2], center_camera)) / np.linalg.norm(center_camera) < .15:
                    continue
                score = support * iou / (1 + rms)
                candidate = {"camera_from_model": pose.tolist(), "inliers": 6,
                             "reprojection_rms_px": rms, "edge_support": support,
                             "silhouette_iou": iou, "score": score}
                found.append(candidate)
    found.sort(key=lambda value: value["score"], reverse=True)
    distinct = []
    for candidate in found:
        pose = np.asarray(candidate["camera_from_model"])
        if any(np.linalg.norm(pose[:3, 3] - np.asarray(other["camera_from_model"])[:3, 3]) < .03
               and np.linalg.norm(pose[:3, :3] - np.asarray(other["camera_from_model"])[:3, :3]) < .15
               for other in distinct):
            continue
        distinct.append(candidate)
    # Do not arbitrarily select the biggest/nearest of multiple plausible boxes.
    status = "not_found" if not distinct else "candidate" if len(distinct) == 1 else "ambiguous"
    return {"status": status, "candidates": distinct[:8]}
