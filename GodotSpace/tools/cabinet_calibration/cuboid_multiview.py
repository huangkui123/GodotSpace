"""Joint upright cuboid fitting across calibrated viewpoints.

Partial-face hypotheses only seed the search. One shared world pose must explain
observed edges in several translated views; a single rectangle cannot authorize
alignment. Camera timing is supplied by the client and remains experimental.
"""
import cv2
import numpy as np
from scipy.optimize import least_squares

from cuboid_faces import edge_map
from cuboid_pose import corners, FACES, _project


def rigid(value):
    matrix = np.asarray(value, float)
    if (matrix.shape != (4, 4) or not np.isfinite(matrix).all()
            or not np.allclose(matrix[3], [0, 0, 0, 1], atol=1e-5)
            or not np.allclose(matrix[:3, :3].T @ matrix[:3, :3], np.eye(3), atol=1e-3)
            or abs(np.linalg.det(matrix[:3, :3]) - 1) > 1e-3):
        raise ValueError('Invalid metric camera transform')
    return matrix


def world_pose(parameters):
    x, y, z, yaw = parameters
    c, s = np.cos(yaw), np.sin(yaw)
    return np.array([[c, 0, s, x], [0, 1, 0, y], [-s, 0, c, z], [0, 0, 0, 1.]])


def prepare(image, k, world_from_camera):
    scale = min(1., 640 / max(image.shape[:2]))
    small = cv2.resize(image, None, fx=scale, fy=scale) if scale < 1 else image
    gray, edges = edge_map(small)
    enhanced = cv2.createCLAHE(clipLimit=3, tileGridSize=(8, 8)).apply(gray)
    gx = cv2.Sobel(enhanced, cv2.CV_32F, 1, 0, ksize=3)
    gy = cv2.Sobel(enhanced, cv2.CV_32F, 0, 1, ksize=3)
    tangent = (np.arctan2(gy, gx) + np.pi / 2) % np.pi
    directional = []
    for angle in np.arange(12) * np.pi / 12:
        difference = np.abs((tangent - angle + np.pi / 2) % np.pi - np.pi / 2)
        selected = ((edges != 0) & (difference < np.deg2rad(20))).astype('uint8') * 255
        directional.append(cv2.distanceTransform(255 - selected, cv2.DIST_L2, 3))
    calibrated = np.asarray(k, float).copy()
    calibrated[:2] *= scale
    return {'distance': cv2.distanceTransform(255 - edges, cv2.DIST_L2, 3),
            'directional_distance': directional,
            'k': calibrated, 'camera': rigid(world_from_camera), 'scale': scale}


def edge_observations(points, pose, view):
    camera_pose = np.linalg.inv(view['camera']) @ pose
    eye = -camera_pose[:3, :3].T @ camera_pose[:3, 3]
    center = points.mean(0)
    errors, face_ids, masks = [], [], []
    for index, face in enumerate(FACES):
        midpoint = points[list(face)].mean(0)
        # Only vertical faces. Top is often covered by objects.
        if index in (2, 3) or np.dot(midpoint - center, eye - midpoint) <= 0:
            continue
        sides, side_masks = [], []
        for a, b in zip(face, face[1:] + face[:1]):
            pixels, depth = _project(np.linspace(points[a], points[b], 32)[2:-2], camera_pose, view['k'])
            distance = view['distance']
            valid = ((depth > .05) & np.isfinite(pixels).all(axis=1)
                     & (pixels[:, 0] >= 0) & (pixels[:, 0] < distance.shape[1] - 1)
                     & (pixels[:, 1] >= 0) & (pixels[:, 1] < distance.shape[0] - 1))
            residual = np.full(len(pixels), 15., dtype=np.float32)
            if valid.any():
                xy = pixels[valid].astype('float32')
                residual[valid] = cv2.remap(distance, xy[:, 0, None], xy[:, 1, None],
                                           cv2.INTER_LINEAR).ravel()
                direction = pixels[-1] - pixels[0]
                angle = np.arctan2(direction[1], direction[0]) % np.pi
                oriented = view['directional_distance'][int(round(angle * 12 / np.pi)) % 12]
                residual[valid] = np.maximum(residual[valid], cv2.remap(
                    oriented, xy[:, 0, None], xy[:, 1, None], cv2.INTER_LINEAR).ravel())
            sides.append(np.minimum(residual, 15))
            side_masks.append(valid)
        errors.append(np.asarray(sides))
        masks.append(np.asarray(side_masks))
        face_ids.append(index)
    return errors, face_ids, masks


def edge_errors(points, pose, view):
    errors, ids, _ = edge_observations(points, pose, view)
    return errors, ids


def _residual(parameters, points, views):
    pose = world_pose(parameters)
    residuals = []
    for view in views:
        faces, _, masks = edge_observations(points, pose, view)
        # Pixels outside the image are unknown, not failed observations. Keep
        # each observed edge's weight independent of its clipped sample count.
        for face, mask in zip(faces, masks):
            for side, visible in zip(face, mask):
                if np.count_nonzero(visible) >= 8:
                    side[~visible] = 0
                    side *= len(side) / np.count_nonzero(visible)
        # Fixed-size residual; one occluded edge per face is permitted.
        faces.sort(key=lambda face: float(np.mean(np.sort(np.mean(face, axis=1))[:3])))
        for i in range(2):
            if i < len(faces):
                order = np.argsort(np.mean(faces[i], axis=1))[:3]
                residuals.extend(faces[i][order].ravel())
            else:
                residuals.extend(np.full(84, 15.))
    return np.asarray(residuals)


def _jacobian(parameters, points, views):
    columns = []
    for index in range(4):
        delta = np.zeros(4)
        delta[index] = .002
        columns.append((_residual(parameters + delta, points, views)
                        - _residual(parameters - delta, points, views)) / .004)
    return np.column_stack(columns)


def fit(views, seeds, size):
    if len(views) < 3:
        return {'status': 'rejected', 'reason': 'need_three_views'}
    cameras = np.array([v['camera'][:3, 3] for v in views])
    if np.max(np.linalg.norm(cameras[:, None] - cameras[None, :], axis=2)) < .12:
        return {'status': 'rejected', 'reason': 'insufficient_baseline'}
    points = corners(size)
    ranked = []
    for seed in seeds:
        seed = rigid(seed)
        if np.dot(seed[:3, 1], [0, 1, 0]) < np.cos(np.deg2rad(12)):
            continue
        params = np.r_[seed[:3, 3], np.arctan2(seed[0, 2], seed[0, 0])]
        residual = _residual(params, points, views)
        ranked.append((float(np.mean(np.minimum(residual, 8))), params))
    ranked.sort(key=lambda pair: pair[0])
    diagnostics = {'seed_count': len(seeds), 'upright_seed_count': len(ranked), 'trials': []}
    candidates = []
    starts = []
    for _, initial in ranked:
        if any(np.linalg.norm(initial[:3] - prior[:3]) < .04
               and abs(np.sin((initial[3] - prior[3]) / 2)) < .03 for prior in starts):
            continue
        starts.append(initial)
        optimized = least_squares(_residual, initial, args=(points, views), jac=_jacobian,
                                  loss='soft_l1', f_scale=2, max_nfev=35)
        pose = world_pose(optimized.x)
        supported = []
        edge_votes = {}
        boundary_votes = {}
        scores = []
        view_evidence = []
        for i, view in enumerate(views):
            faces, ids, masks = edge_observations(points, pose, view)
            observed = {}
            face_evidence = []
            for errors, face_id, mask in zip(faces, ids, masks):
                face = FACES[face_id]
                face_evidence.append({'face_id': face_id,
                                      'visible_fraction': np.mean(mask, axis=1).tolist(),
                                      'edge_coverage': [float(np.mean(e[v] < 3.5)) if v.any() else None
                                                        for e, v in zip(errors, mask)]})
                for a, b, error, valid in zip(face, face[1:] + face[:1], errors, mask):
                    if np.count_nonzero(valid) < 8:
                        continue
                    support = float(np.mean(error[valid] < 3.5))
                    if support >= .65:
                        observed[tuple(sorted((a, b)))] = support
            # Every accepted view must contribute several actual box edges.
            # Complementary views may expose different edges of the same box.
            vertical = sum(abs(points[a, 1] - points[b, 1]) > .01 for a, b in observed)
            view_evidence.append({'view_index': i, 'faces': face_evidence,
                                  'supported_edge_count': len(observed), 'vertical_edges': int(vertical)})
            if len(observed) >= 4 and vertical >= 2 and len(observed) - vertical >= 2:
                if any(np.linalg.norm(cameras[i] - cameras[prior]) < .04 for prior in supported):
                    continue
                supported.append(i)
                for edge in observed:
                    edge_votes[edge] = edge_votes.get(edge, 0) + 1
                    # Sparse accidental matches on floor tiles must not close
                    # a face whose top was actually an internal door seam.
                    if observed[edge] >= .85:
                        boundary_votes[edge] = boundary_votes.get(edge, 0) + 1
                scores.append(float(np.mean(list(observed.values()))))
        # Require repeated evidence of both faces, including their unshared
        # edges. A single flat panel or one accidental frame cannot pass.
        face_support = []
        boundary_support = []
        for index, face in enumerate(FACES):
            if index not in (2, 3):
                face_support.append(sum(edge_votes.get(tuple(sorted((a, b))), 0) >= 2
                                        for a, b in zip(face, face[1:] + face[:1])))
                boundary_support.append(sum(boundary_votes.get(tuple(sorted((a, b))), 0) >= 2
                                            for a, b in zip(face, face[1:] + face[:1])))
        diagnostics['trials'].append({'world_from_model': pose.tolist(),
                                     'supported_view_indices': supported.copy(),
                                     'repeated_edges_per_vertical_face': face_support,
                                     'repeated_boundaries_per_vertical_face': boundary_support,
                                     'mean_residual_px': float(np.mean(optimized.fun)),
                                     'views': view_evidence})
        if (len(supported) >= 3 and max(boundary_support) == 4
                and sum(n >= 3 for n in face_support) >= 2):
            centers = cameras[supported]
            target = pose[:3, :3] @ points.mean(0) + pose[:3, 3]
            rays = centers - target
            rays /= np.linalg.norm(rays, axis=1)[:, None]
            if (np.max(np.linalg.norm(centers[:, None] - centers[None, :], axis=2)) >= .12
                    and np.min(rays @ rays.T) < np.cos(np.deg2rad(8))):
                candidates.append({'pose': pose, 'supported': supported, 'score': float(np.mean(scores))})
        if len(starts) >= 12:
            break
    # Canonical front is chosen once using the first view, NOT per frame.
    center = points.mean(0)
    for candidate in candidates:
        pose = candidate['pose']
        eye = np.linalg.inv(pose) @ np.r_[cameras[0], 1]
        angle = np.pi if eye[2] < center[2] else 0.
        if abs(size[0] - size[2]) < 1e-6:
            angle = round(np.arctan2(eye[0] - center[0], eye[2] - center[2]) / (np.pi / 2)) * np.pi / 2
        symmetry = world_pose([0, 0, 0, angle])
        symmetry[:3, 3] = center - symmetry[:3, :3] @ center
        candidate['pose'] = pose @ symmetry
    candidates.sort(key=lambda c: (-len(c['supported']), -c['score']))
    distinct = []
    for candidate in candidates:
        pose = candidate['pose']
        if not any(np.linalg.norm(pose[:3, 3] - other['pose'][:3, 3]) < .04
                   and np.linalg.norm(pose[:3, :3] - other['pose'][:3, :3]) < .15 for other in distinct):
            distinct.append(candidate)
    if len(distinct) != 1:
        return {'status': 'rejected', 'reason': 'ambiguous' if distinct else 'insufficient_edge_support',
                'diagnostics': diagnostics}
    best = distinct[0]
    return {'status': 'candidate', 'world_from_model': best['pose'].tolist(),
            'support_indices': best['supported'], 'edge_score': best['score'], 'diagnostics': diagnostics}
