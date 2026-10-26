from itertools import combinations
from unittest import TestCase

import numpy as np
from scipy.spatial.transform import Rotation

from camera_timing import choose_timing, correspondences, epipolar_errors


def camera(t):
    pose = np.eye(4)
    pose[:3, :3] = Rotation.from_euler('yx', [.2 * np.sin(2 * t), .05 * np.cos(t)]).as_matrix()
    pose[:3, 3] = [.3 * np.sin(t), .05 * np.cos(t), .06 * t]
    return pose


def fixture():
    rng = np.random.default_rng(123)
    points = rng.uniform([-1, -.8, 3], [1, .8, 5], size=(100, 3))
    times = [.5, 1.4, 2.1, 3.1]
    k = np.array([[610., 0, 479.5], [0, 610., 359.5], [0, 0, 1]])
    paths = {delay: [camera(t + .12 - delay / 1000) for t in times] for delay in range(0, 401, 10)}
    pixels = []
    for pose in paths[120]:
        local = (points - pose[:3, 3]) @ pose[:3, :3]
        uv = local @ k.T
        pixels.append(uv[:, :2] / uv[:, 2:])
    pairs = [(a, b, pixels[a], pixels[b]) for a, b in combinations(range(len(times)), 2)]
    return paths, [k] * 4, pairs


class CameraTimingTests(TestCase):
    def test_recovers_common_exposure_delay_from_recorded_poses(self):
        paths, intrinsics, pairs = fixture()
        result = choose_timing(paths, intrinsics, pairs)
        self.assertEqual(result['status'], 'verified', result)
        self.assertEqual(result['delay_ms'], 120)
        self.assertEqual(result['support_indices'], [0, 1, 2, 3])
        self.assertLess(result['median_epipolar_px'], 1e-6)
        self.assertGreater(result['arrival_median_epipolar_px'], 3)

    def test_arrival_poses_alone_cannot_authorize_wrong_alignment(self):
        paths, intrinsics, pairs = fixture()
        self.assertEqual(choose_timing({0: paths[0]}, intrinsics, pairs)['status'], 'rejected')

    def test_rejects_outlier_camera_instead_of_adjusting_it_independently(self):
        paths, intrinsics, pairs = fixture()
        for poses in paths.values():
            poses[3] = poses[3].copy()
            poses[3][:3, :3] = Rotation.from_euler('x', 40, degrees=True).as_matrix()
        result = choose_timing(paths, intrinsics, pairs)
        self.assertEqual(result['support_indices'], [0, 1, 2])
        self.assertEqual(result['delay_ms'], 120)

    def test_feature_chain_is_not_a_pairwise_consistent_group(self):
        paths, intrinsics, pairs = fixture()
        chain = [p for p in pairs if p[1] == p[0] + 1]
        self.assertEqual(choose_timing(paths, intrinsics, chain)['status'], 'rejected')

    def test_blank_images_cannot_verify_timing(self):
        self.assertEqual(correspondences([np.zeros((240, 320), np.uint8)] * 3), [])
        self.assertEqual(choose_timing({0: [np.eye(4)] * 3}, [np.eye(3)] * 3, [])['reason'],
                         'timing_features_insufficient')

    def test_perfect_projections_have_zero_epipolar_error(self):
        paths, intrinsics, pairs = fixture()
        a, b, p, q = pairs[0]
        errors = epipolar_errors(paths[120][a], paths[120][b], intrinsics[a], intrinsics[b], p, q)
        self.assertLess(float(np.max(errors)), 1e-8)
