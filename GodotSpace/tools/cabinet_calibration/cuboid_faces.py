"""Partial cabinet-face proposals from observed straight lines, not a closed hull.

These are geometric proposals, not object identities or metric poses. A desktop,
door or inset panel can also produce one; multi-view validation is mandatory.
"""
from itertools import combinations

import cv2
import numpy as np


def edge_map(image):
    gray = cv2.cvtColor(image, cv2.COLOR_BGR2GRAY)
    enhanced = cv2.createCLAHE(clipLimit=2, tileGridSize=(8, 8)).apply(gray)
    edges = cv2.Canny(cv2.GaussianBlur(gray, (3, 3), .6), 35, 100)
    edges |= cv2.Canny(cv2.GaussianBlur(enhanced, (3, 3), .6), 35, 100)
    return gray, edges


def _intersection(a, b):
    p, q = a
    r, s = b
    matrix = np.column_stack((q - p, r - s))
    if abs(np.linalg.det(matrix)) < 1:
        return None
    return p + np.linalg.solve(matrix, r - p)[0] * (q - p)


def face_proposals(image, limit=24):
    # Work in bounded image coordinates, returning original-image pixels.
    scale = min(1., 1280 / max(image.shape[:2]))
    small = cv2.resize(image, None, fx=scale, fy=scale) if scale < 1 else image
    gray, edges = edge_map(small)
    detected = cv2.createLineSegmentDetector(cv2.LSD_REFINE_STD).detect(gray)[0]
    if detected is None:
        return []
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
            # Loose proposal merge tolerates lens curvature and cabinet trim.
            # The joint solver later checks the actual pixels at a much tighter
            # tolerance; this merge does not count as pose evidence.
            if max(abs((segment - a) @ normal)) > 18:
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
            if any(p[1] < side[:, 1].min() - 35 or p[1] > side[:, 1].max() + 35
                   for p, side in [(a, left), (b, right)]):
                continue
            # A short unrelated line cannot be extended across the whole face.
            if np.linalg.norm(line[1] - line[0]) < .5 * np.linalg.norm(b - a):
                continue
            crossings.append((a, b))
        for first, second in combinations(crossings, 2):
            top, bottom = sorted([first, second], key=lambda pair: (pair[0][1] + pair[1][1]) / 2)
            polygon = np.array([top[0], top[1], bottom[1], bottom[0]], dtype=np.float32)
            if (np.any(polygon < 2) or np.any(polygon >= [width - 2, height - 2])
                    or not cv2.isContourConvex(polygon) or cv2.contourArea(polygon) < width * height * .025):
                continue
            sides = np.linalg.norm(polygon - np.roll(polygon, 1, axis=0), axis=1)
            if min(sides) < 50:
                continue
            coverage = []
            for a, b in zip(polygon, np.roll(polygon, -1, axis=0)):
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


def pose_seeds(image, k, size, camera_up):
    """Planar-face hypotheses. Never sufficient alone to enable alignment."""
    from cuboid_pose import corners
    points = corners(size)
    up = np.asarray(camera_up, float)
    seeds = []
    # Both width and depth faces may be visible. Leave symmetric alternatives
    # for joint validation rather than pretending a single panel is a box.
    for proposal in face_proposals(image):
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
