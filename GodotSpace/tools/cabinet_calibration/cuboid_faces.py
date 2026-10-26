"""Partial cabinet-face proposals from observed straight lines, not a closed hull.

These are geometric proposals, not object identities or metric poses. A desktop,
door or inset panel can also produce one; multi-view validation is mandatory.
"""
from itertools import combinations

import cv2
import numpy as np


def edge_map(image):
    gray = cv2.cvtColor(image, cv2.COLOR_BGR2GRAY)
    enhanced = cv2.createCLAHE(clipLimit=3, tileGridSize=(8, 8)).apply(gray)
    edges = cv2.Canny(cv2.GaussianBlur(gray, (3, 3), .6), 35, 100)
    # Matte white panels often differ by only a few intensity levels. These
    # pixels propose/support edges; they never establish a cabinet on their own.
    edges |= cv2.Canny(cv2.GaussianBlur(enhanced, (3, 3), .6), 12, 35)
    return gray, edges


def _intersection(a, b):
    p, q = a
    r, s = b
    matrix = np.column_stack((q - p, r - s))
    if abs(np.linalg.det(matrix)) < 1:
        return None
    return p + np.linalg.solve(matrix, r - p)[0] * (q - p)


def _line_evidence(image):
    # Work in bounded image coordinates, returning original-image pixels.
    scale = min(1., 1280 / max(image.shape[:2]))
    small = cv2.resize(image, None, fx=scale, fy=scale) if scale < 1 else image
    gray, edges = edge_map(small)
    enhanced = cv2.createCLAHE(clipLimit=3, tileGridSize=(8, 8)).apply(gray)
    detected = cv2.createLineSegmentDetector(cv2.LSD_REFINE_STD).detect(enhanced)[0]
    if detected is None:
        return gray, edges, [], [], scale
    segments = detected.reshape(-1, 2, 2).astype(float)
    lengths = np.linalg.norm(segments[:, 1] - segments[:, 0], axis=1)
    segments = segments[np.argsort(-lengths)]
    groups = []
    for segment in segments[:300]:
        p, q = segment
        length = np.linalg.norm(q - p)
        if length < 35:
            continue
        direction = (q - p) / length
        matched = False
        for group in groups:
            a, b = group[0]
            axis = (b - a) / np.linalg.norm(b - a)
            normal = np.array([-axis[1], axis[0]])
            if abs(axis @ direction) < np.cos(np.deg2rad(4)):
                continue
            # Do not merge the cabinet corner with a nearby desk leg or inset
            # door trim. That moves the fitted line off the observed boundary.
            if max(abs((segment - a) @ normal)) > 4:
                continue
            points = np.concatenate(group)
            along = (points - a) @ axis
            trial = (segment - a) @ axis
            if trial.min() > along.max() + 260 or trial.max() < along.min() - 260:
                continue
            group.append(segment)
            matched = True
            break
        if not matched:
            groups.append([segment])
    lines = []
    for group in groups:
        points = np.concatenate(group)
        vx, vy, x, y = cv2.fitLine(points.astype('float32'), cv2.DIST_L2, 0, .01, .01).ravel()
        axis, center = np.array([vx, vy]), np.array([x, y])
        extent = (points - center) @ axis
        line = np.array([center + extent.min() * axis, center + extent.max() * axis])
        if np.linalg.norm(line[1] - line[0]) >= 90:
            lines.append(line)
    vertical = [line for line in lines if abs((line[1] - line[0])[1]) > 2 * abs((line[1] - line[0])[0])]
    transverse = [line for line in lines if abs((line[1] - line[0])[1]) < 1.5 * abs((line[1] - line[0])[0])]
    return gray, edges, vertical, transverse, scale


def face_proposals(image, limit=24):
    gray, edges, vertical, transverse, scale = _line_evidence(image)
    distance = cv2.distanceTransform(255 - edges, cv2.DIST_L2, 3)
    height, width = gray.shape
    proposals = []
    for left, right in combinations(vertical[:40], 2):
        if left[:, 0].mean() > right[:, 0].mean():
            left, right = right, left
        if right[:, 0].mean() - left[:, 0].mean() < 60:
            continue
        crossings = []
        for line in transverse[:60]:
            a, b = _intersection(left, line), _intersection(right, line)
            if a is None or b is None or a[0] >= b[0]:
                continue
            # A faint corner may only be detected along part of its height.
            # Extend proposals, then verify all four sides against image pixels.
            if any(p[1] < side[:, 1].min() - height * .55 or p[1] > side[:, 1].max() + height * .55
                   for p, side in [(a, left), (b, right)]):
                continue
            # A short unrelated line cannot be extended across the whole face.
            if np.linalg.norm(line[1] - line[0]) < .5 * np.linalg.norm(b - a):
                continue
            # Check a cross-edge once, before combining it with every other
            # cross-edge. Also require the detected segment to overlap the face.
            if np.any(np.array([a, b]) < 2) or np.any(np.array([a, b]) >= [width - 2, height - 2]):
                continue
            axis = (b - a) / np.linalg.norm(b - a)
            span = (line - a) @ axis
            overlap = min(span.max(), np.linalg.norm(b - a)) - max(span.min(), 0)
            if overlap < .5 * np.linalg.norm(b - a):
                continue
            samples = np.rint(np.linspace(a, b, 100)[3:-3]).astype(int)
            support = float(np.mean(distance[samples[:, 1], samples[:, 0]] < 4))
            if support >= .55:
                crossings.append((a, b, support))
        for first, second in combinations(crossings, 2):
            top, bottom = sorted([first, second], key=lambda pair: (pair[0][1] + pair[1][1]) / 2)
            polygon = np.array([top[0], top[1], bottom[1], bottom[0]], dtype=np.float32)
            if (np.any(polygon < 2) or np.any(polygon >= [width - 2, height - 2])
                    or not cv2.isContourConvex(polygon) or cv2.contourArea(polygon) < width * height * .025):
                continue
            sides = np.linalg.norm(polygon - np.roll(polygon, 1, axis=0), axis=1)
            if min(sides) < 50:
                continue
            coverage = [top[2], bottom[2]]
            for a, b in [(polygon[1], polygon[2]), (polygon[3], polygon[0])]:
                samples = np.rint(np.linspace(a, b, 100)[3:-3]).astype(int)
                coverage.append(np.mean(distance[samples[:, 1], samples[:, 0]] < 4))
            if min(coverage) < .55 or np.mean(coverage) < .8:
                continue
            if any(np.mean(np.linalg.norm(polygon - other['pixels'], axis=1)) < 12 for other in proposals):
                continue
            proposals.append({'pixels': polygon, 'support': float(np.mean(coverage)),
                              'area': float(cv2.contourArea(polygon))})
    proposals.sort(key=lambda item: -item['area'] * item['support'])
    return [{'pixels': (item['pixels'] / scale).tolist(), 'support': item['support'],
             'area': item['area'] / scale ** 2} for item in proposals[:limit]]


def partial_pose_seeds(image, k, size, camera_up):
    """Use gravity and a visible horizontal edge between two upright lines.

    No bottom/top closure is required. Equal endpoint height fixes the ray-depth
    ratio; the configured edge length fixes metric scale. These are only search
    starts and still require the independent multi-view image validation.
    """
    from cuboid_pose import corners, _project
    points = corners(size)
    up = np.asarray(camera_up, float)
    up /= np.linalg.norm(up)
    gray, edges, vertical, transverse, scale = _line_evidence(image)
    calibrated = np.asarray(k, float).copy()
    calibrated[:2] *= scale
    inverse = np.linalg.inv(calibrated)
    distance = cv2.distanceTransform(255 - edges, cv2.DIST_L2, 3)
    height, width = gray.shape
    upright = []
    for line in vertical[:40]:
        rays = np.c_[line, np.ones(2)] @ inverse.T
        normal = np.cross(*rays)
        normal /= np.linalg.norm(normal)
        if abs(normal @ up) < np.sin(np.deg2rad(3)):
            upright.append(line)
    seeds = []
    centers = np.empty((128, 3))
    for left, right in combinations(upright, 2):
        if left[:, 0].mean() > right[:, 0].mean():
            left, right = right, left
        for line in transverse[:60]:
            a, b = _intersection(left, line), _intersection(right, line)
            if a is None or b is None or b[0] - a[0] < 50:
                continue
            pixels = np.array([a, b])
            if np.any(pixels < 2) or np.any(pixels >= [width - 2, height - 2]):
                continue
            axis = (b - a) / np.linalg.norm(b - a)
            span = (line - a) @ axis
            if min(span.max(), np.linalg.norm(b - a)) - max(span.min(), 0) < .5 * np.linalg.norm(b - a):
                continue
            samples = np.rint(np.linspace(a, b, 60)[2:-2]).astype(int)
            if np.mean(distance[samples[:, 1], samples[:, 0]] < 3) < .8:
                continue
            rays = np.c_[pixels, np.ones(2)] @ inverse.T
            heights = rays @ up
            if min(abs(heights)) < .03 or heights[0] * heights[1] <= 0:
                continue
            ratio = heights[0] / heights[1]
            for start, end in [(0, 1), (5, 4), (4, 0), (1, 5),
                               (3, 2), (6, 7), (7, 3), (2, 6)]:
                local = points[end] - points[start]
                length = np.linalg.norm(local)
                depth = length / np.linalg.norm(rays[0] - rays[1] * ratio)
                ca, cb = depth * rays[0], depth * ratio * rays[1]
                along = (cb - ca) / length
                local /= length
                x = local[0] * along + local[2] * np.cross(up, along)
                pose = np.eye(4)
                pose[:3, :3] = np.column_stack((x, up, np.cross(x, up)))
                pose[:3, 3] = ca - pose[:3, :3] @ points[start]
                uv, depths = _project(points, pose, calibrated)
                if depths.min() <= .05:
                    continue
                # The proposed face's two vertical lines must be visible in the
                # image, not just tiny desk fragments extended arbitrarily.
                vertical_support = []
                for index in [start, end]:
                    other = (3, 2, 1, 0, 7, 6, 5, 4)[index]
                    sample = np.linspace(uv[index], uv[other], 60)[2:-2]
                    valid = ((sample[:, 0] >= 0) & (sample[:, 0] < width - 1)
                             & (sample[:, 1] >= 0) & (sample[:, 1] < height - 1))
                    if valid.sum() < 16:
                        vertical_support.append(0.)
                    else:
                        xy = np.rint(sample[valid]).astype(int)
                        vertical_support.append(float(np.mean(distance[xy[:, 1], xy[:, 0]] < 4)))
                if min(vertical_support) < .6:
                    continue
                nearby = np.flatnonzero(np.linalg.norm(centers[:len(seeds)] - pose[:3, 3], axis=1) < .025)
                if any(np.linalg.norm(pose[:3, :3] - seeds[i][:3, :3]) < .08 for i in nearby):
                    continue
                if len(seeds) == len(centers):
                    centers = np.concatenate((centers, np.empty_like(centers)))
                centers[len(seeds)] = pose[:3, 3]
                seeds.append(pose)
    return seeds


def pose_seeds(image, k, size, camera_up, proposals=None):
    """Planar-face hypotheses. Never sufficient alone to enable alignment."""
    from cuboid_pose import corners
    points = corners(size)
    up = np.asarray(camera_up, float)
    seeds = []
    # Both width and depth faces may be visible. Leave symmetric alternatives
    # for joint validation rather than pretending a single panel is a box.
    for proposal in face_proposals(image) if proposals is None else proposals:
        pixels = np.asarray(proposal['pixels'], float)
        for indices in [(0, 1, 2, 3), (5, 4, 7, 6), (4, 0, 3, 7), (1, 5, 6, 2)]:
            obj = np.ascontiguousarray(points[list(indices)])
            ok, rvecs, tvecs, _ = cv2.solvePnPGeneric(obj, pixels, k, None, flags=cv2.SOLVEPNP_IPPE)
            if not ok:
                continue
            for rvec, tvec in zip(rvecs, tvecs):
                pose = np.eye(4)
                pose[:3, :3], pose[:3, 3] = cv2.Rodrigues(rvec)[0], tvec.ravel()
                projected, _ = cv2.projectPoints(obj, rvec, tvec, k, None)
                rms = np.sqrt(np.mean(np.sum((projected.reshape(-1, 2) - pixels) ** 2, axis=1)))
                if (not np.isfinite(pose).all() or not np.isfinite(rms) or rms > 5
                        or np.dot(pose[:3, 1], up) < np.cos(np.deg2rad(12))
                        or (points @ pose[:3, :3].T + pose[:3, 3])[:, 2].min() <= .05):
                    continue
                seeds.append(pose)
    return seeds
