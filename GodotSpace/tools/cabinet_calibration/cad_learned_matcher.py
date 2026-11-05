"""Local CAD-render/photograph matching; geometry still decides acceptance.

No field photographs or image coordinates are embedded in this matcher. Render
coordinates come from the hash-checked CAD mesh. Weights are provisioned offline;
recognition never downloads anything. The caller must enforce camera timing and
independent multi-view pose consensus before offering alignment.
"""
from collections import OrderedDict
import os
from pathlib import Path
import time

import cv2
import numpy as np
from scipy.spatial.transform import Rotation

from geometry import sha256
from render_model import camera_pose, render
from rgb_pose import fit_correspondences

WEIGHT_SHA256 = "21f5bec5968178e8bc8b7633441836fe5de4f47d861dd2cd7dc38e271b0479ec"
WEIGHT_URL = "https://huggingface.co/kornia/loftr/resolve/0fb3b456cf176746709c38fa9cf80695a1c82dac/loftr_outdoor.ckpt"


def weight_path():
    configured = os.environ.get('GODOTSPACE_CABINET_MATCHER_WEIGHTS')
    if configured:
        return Path(configured)
    return Path(os.environ.get('LOCALAPPDATA', str(Path.home() / '.cache'))) / 'GodotSpace/cabinet-calibration-models/loftr_outdoor.ckpt'


def eligible_pose(pose, image_shape, model_height):
    """Reject small repeated fittings even when their local PnP residual is low."""
    return bool(pose is not None and pose['inliers'] >= 20
            and pose['image_hull_area_px2'] >= image_shape[0] * image_shape[1] * .02
            and pose['inlier_object_span_m'][1] >= model_height * .35)


def choose_candidate(candidates):
    if not candidates:
        return {'status': 'not_found', 'candidates': []}
    candidates.sort(key=lambda p: -p['score'])
    best = candidates[0]
    transform = np.asarray(best['camera_from_model'])
    for other in candidates[1:]:
        matrix = np.asarray(other['camera_from_model'])
        angle = Rotation.from_matrix(transform[:3, :3].T @ matrix[:3, :3]).magnitude()
        if other['score'] >= best['score'] * .75 and (angle > np.deg2rad(10)
                or np.linalg.norm(transform[:3, 3] - matrix[:3, 3]) > .03):
            return {'status': 'ambiguous', 'candidates': candidates[:8]}
    return {'status': 'candidate', 'candidates': candidates[:8]}


class CadLearnedMatcher:
    def __init__(self, mesh, weights=None, max_seconds=75, max_pairs=36):
        path = Path(weights) if weights is not None else weight_path()
        if sha256(path) != WEIGHT_SHA256:
            raise ValueError('CAD matcher weight checksum mismatch; rerun setup_cad_matcher.py')
        import torch
        from kornia.feature import LoFTR
        self.torch = torch
        torch.set_num_threads(min(4, max(1, os.cpu_count() or 1)))
        self.model = LoFTR(pretrained=None).eval()
        self.model.load_state_dict(torch.load(path, map_location='cpu', weights_only=True)['state_dict'])
        self.mesh = mesh
        self.cache = OrderedDict()
        self.preferred_yaw = None
        self.search_offset = 0
        self.pairs = 0
        self.timings = {'reference_render_and_features_seconds': 0., 'query_features_seconds': 0.,
                        'network_matching_seconds': 0., 'pnp_seconds': 0.}
        self.max_pairs = max_pairs
        self.deadline = time.monotonic() + max_seconds

    def _tensor(self, image):
        return self.torch.from_numpy(cv2.cvtColor(image, cv2.COLOR_BGR2GRAY)).float()[None, None] / 255

    def _reference(self, yaw):
        if yaw in self.cache:
            self.cache.move_to_end(yaw)
            return self.cache[yaw]
        started = time.perf_counter()
        k = np.array([[487.5, 0, 240], [0, 487.5, 240], [0, 0, 1]], dtype=float)
        pose = camera_pose(self.mesh.bounds.mean(0), self.mesh.extents.max() * 1.6, yaw, 15)
        rgb, xyz = render(self.mesh, pose, k, size=(480, 480), background=120)
        with self.torch.inference_mode():
            features = self.model.extract_features(self._tensor(rgb))
        self.cache[yaw] = (features, xyz)
        self.timings['reference_render_and_features_seconds'] += time.perf_counter() - started
        # Dense feature maps are sizable: bound the per-job cache.
        while len(self.cache) > 6:
            self.cache.popitem(last=False)
        return features, xyz

    def estimate(self, image, k, distortion):
        if time.monotonic() >= self.deadline or self.pairs >= self.max_pairs:
            return {'status': 'not_found', 'candidates': [], 'reason': 'learned_budget_exhausted'}
        height, width = image.shape[:2]
        scale = min(1., 640 / max(height, width))
        size = tuple(max(8, int(round(n * scale / 8)) * 8) for n in (width, height))
        query = cv2.resize(image, size) if size != (width, height) else image
        started = time.perf_counter()
        with self.torch.inference_mode():
            query_features = self.model.extract_features(self._tensor(query))
        self.timings['query_features_seconds'] += time.perf_counter() - started
        # Broad view search, then neighboring renders as the observer moves.
        # These are model-relative camera angles, never stored field poses.
        search = [90, 45, 135, 0, 180, 225, 270, 315]
        if self.preferred_yaw is None:
            angles = [search[(self.search_offset + i) % len(search)] for i in range(3)]
            self.search_offset = (self.search_offset + 3) % len(search)
        else:
            angles = [self.preferred_yaw, (self.preferred_yaw + 20) % 360,
                      (self.preferred_yaw - 20) % 360]
        candidates, attempts = [], []
        for yaw in angles:
            if time.monotonic() >= self.deadline or self.pairs >= self.max_pairs:
                break
            reference, xyz = self._reference(yaw)
            started = time.perf_counter()
            with self.torch.inference_mode():
                matched = self.model({'features0': reference, 'features1': query_features})
            self.timings['network_matching_seconds'] += time.perf_counter() - started
            self.pairs += 1
            pixels = matched['keypoints1'].numpy() * [width / size[0], height / size[1]]
            xy = np.rint(matched['keypoints0'].numpy()).astype(int)
            valid = ((matched['confidence'].numpy() > .5) & (xy[:, 0] >= 0)
                     & (xy[:, 0] < 480) & (xy[:, 1] >= 0) & (xy[:, 1] < 480))
            xy, pixels = xy[valid], pixels[valid]
            points = xyz[xy[:, 1], xy[:, 0]]
            valid = np.isfinite(points).all(1)
            points, pixels = points[valid], pixels[valid]
            started = time.perf_counter()
            pose = fit_correspondences(points, pixels, k, distortion) if len(points) >= 20 else None
            self.timings['pnp_seconds'] += time.perf_counter() - started
            accepted = eligible_pose(pose, image.shape, self.mesh.extents[1])
            attempts.append({'yaw': yaw, 'matches': len(points),
                             'inliers': pose['inliers'] if pose else 0, 'accepted': accepted})
            if accepted:
                pose.update(template=f'cad_render_{yaw}', template_yaw=yaw, matcher='loftr')
                candidates.append(pose)
        result = choose_candidate(candidates)
        result['diagnostics'] = {'attempts': attempts, 'pairs_used': self.pairs}
        if result['status'] == 'candidate':
            self.preferred_yaw = result['candidates'][0]['template_yaw']
        elif not candidates:
            self.preferred_yaw = None
        return result
