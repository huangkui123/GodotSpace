"""Check image/tracking agreement and select a bounded common capture delay.

Arrival time is not exposure time. Match static image features before trusting
the tracked cameras; use only recorded poses, never extrapolate or adjust a
camera independently to make a cabinet fit.
"""
from itertools import combinations

import cv2
import numpy as np

MAX_DELAY_MS = 400
STEP_MS = 10


def correspondences(images):
    detector = cv2.SIFT_create(nfeatures=1600)
    features = [detector.detectAndCompute(image, None) for image in images]
    pairs = []
    for a, b in combinations(range(len(images)), 2):
        ka, da = features[a]
        kb, db = features[b]
        if da is None or db is None or min(len(da), len(db)) < 24:
            continue
        matches = [m for m, n in cv2.BFMatcher().knnMatch(da, db, k=2) if m.distance < .7 * n.distance]
        if len(matches) < 24:
            continue
        p = np.array([ka[m.queryIdx].pt for m in matches])
        q = np.array([kb[m.trainIdx].pt for m in matches])
        cv2.setRNGSeed(0)
        _, mask = cv2.findFundamentalMat(p, q, cv2.FM_RANSAC, 1.5, .999)
        if mask is None:
            continue
        good = mask.ravel() != 0
        p, q = p[good], q[good]
        if len(p) < 24:
            continue
        # A tiny patch on an independently moving object is not timing evidence.
        if any(np.any(np.ptp(points, axis=0) < np.array(image.shape[:2][::-1]) * .25)
               for points, image in [(p, images[a]), (q, images[b])]):
            continue
        pairs.append((a, b, p, q))
    return pairs


def epipolar_errors(a, b, ka, kb, p, q):
    relative = np.linalg.inv(b) @ a
    x, y, z = relative[:3, 3]
    cross = np.array([[0, -z, y], [z, 0, -x], [-y, x, 0]])
    fundamental = np.linalg.inv(kb).T @ cross @ relative[:3, :3] @ np.linalg.inv(ka)
    hp, hq = np.c_[p, np.ones(len(p))], np.c_[q, np.ones(len(q))]
    lq, lp = hp @ fundamental.T, hq @ fundamental
    denominator = np.minimum(np.linalg.norm(lq[:, :2], axis=1), np.linalg.norm(lp[:, :2], axis=1))
    return np.abs(np.sum(lq * hq, axis=1)) / np.maximum(denominator, 1e-12)


def _cliques(neighbors):
    found = []

    def visit(chosen, possible, excluded):
        if not possible and not excluded:
            found.append(sorted(chosen))
            return
        pivot = max(possible | excluded, key=lambda v: len(possible & neighbors[v]), default=None)
        for v in sorted(possible - (neighbors[pivot] if pivot is not None else set())):
            visit(chosen | {v}, possible & neighbors[v], excluded & neighbors[v])
            possible.remove(v)
            excluded.add(v)

    visit(set(), set(range(len(neighbors))), set())
    return found


def choose_timing(cameras_by_delay, intrinsics, pairs):
    """Require consistent, cycle-supported overlap; missing overlap is unknown."""
    if not pairs:
        return {'status': 'rejected', 'reason': 'timing_features_insufficient', 'matched_pairs': 0}
    ranked = []
    original_errors = []
    for delay, cameras in cameras_by_delay.items():
        neighbors = [set() for _ in cameras]
        compatible = [set(range(len(cameras))) - {i} for i in range(len(cameras))]
        scores = {}
        for a, b, p, q in pairs:
            if np.linalg.norm(cameras[a][:3, 3] - cameras[b][:3, 3]) < .025:
                continue
            error = epipolar_errors(cameras[a], cameras[b], intrinsics[a], intrinsics[b], p, q)
            median = float(np.median(error))
            if delay == 0:
                original_errors.append(median)
            if median <= 3 and np.percentile(error, 90) <= 6:
                neighbors[a].add(b)
                neighbors[b].add(a)
                scores[a, b] = median
            else:
                compatible[a].discard(b)
                compatible[b].discard(a)
        for compatible_group in _cliques(compatible):
            # Do not discard views simply because they no longer see the same
            # background patch. Retain the 2-core of measured overlap instead;
            # a chain without loop evidence still cannot verify timing.
            core = set(compatible_group)
            while True:
                weak = {i for i in core if len(neighbors[i] & core) < 2}
                if not weak:
                    break
                core -= weak
            if not core:
                continue
            while core:
                connected, pending = set(), {min(core)}
                while pending:
                    vertex = pending.pop()
                    connected.add(vertex)
                    pending |= (neighbors[vertex] & core) - connected
                core -= connected
                group = sorted(connected)
                positions = np.array([cameras[i][:3, 3] for i in group])
                if np.max(np.linalg.norm(positions[:, None] - positions[None, :], axis=2)) < .12:
                    continue
                score = float(np.mean([scores[a, b] for a, b in combinations(group, 2) if (a, b) in scores]))
                ranked.append((-len(group), score, delay, group))
    diagnostic = {'matched_pairs': len(pairs),
                  'arrival_median_epipolar_px': float(np.median(original_errors)) if original_errors else None}
    if not ranked:
        return dict(diagnostic, status='rejected', reason='image_pose_mismatch')
    ranked.sort()
    _, score, delay, group = ranked[0]
    return dict(diagnostic, status='verified', delay_ms=delay, support_indices=group,
                median_epipolar_px=score)


def check(frames, decode_frame):
    # The request is bounded to 16 frames. Retain only <= 960px grayscale images.
    from cuboid_multiview import rigid
    images, intrinsics, paths = [], [], []
    has_history = all('camera_history' in frame for frame in frames)
    if any('camera_history' in frame for frame in frames) and not has_history:
        raise ValueError('Incomplete camera timing history')
    delays = list(range(0, MAX_DELAY_MS + 1, STEP_MS)) if has_history else [0]
    for frame in frames:
        image, k, _ = decode_frame(frame)
        scale = min(1., 960 / max(image.shape[:2]))
        gray = cv2.cvtColor(image, cv2.COLOR_BGR2GRAY)
        if scale < 1:
            gray = cv2.resize(gray, None, fx=scale, fy=scale)
        images.append(gray)
        k = k.copy()
        k[:2] *= scale
        intrinsics.append(k)
        path = frame.get('camera_history', [frame['world_from_camera']])
        if not isinstance(path, list) or len(path) != len(delays):
            raise ValueError('Invalid camera timing history length')
        matrices = [rigid(value) for value in path]
        if not np.allclose(matrices[0], rigid(frame['world_from_camera']), atol=1e-5):
            raise ValueError('Camera history does not start at the captured pose')
        paths.append(matrices)
    cameras = {delay: [path[i] for path in paths] for i, delay in enumerate(delays)}
    result = choose_timing(cameras, intrinsics, correspondences(images))
    result['history_available'] = has_history
    return result, cameras.get(result.get('delay_ms', 0))
