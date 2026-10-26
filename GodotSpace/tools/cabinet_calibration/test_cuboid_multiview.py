import base64
from pathlib import Path
from unittest import TestCase

import cv2
import numpy as np

from cuboid_faces import pose_seeds
from cuboid_multiview import fit, prepare, rigid
from cuboid_pose import DEFAULT_DIMENSIONS, estimate_cuboid, corners, _project
from test_cuboid_pose import scene
from visual_pose_worker import run_job


def sequence(occluded=True):
    views, seeds, frames = [], [], []
    for index, yaw in enumerate([25, 35, 45]):
        image, k, camera_pose = scene(DEFAULT_DIMENSIONS, yaw)
        if occluded:
            cv2.rectangle(image, (0, 400), (305, 639), (65, 65, 65), -1)
        camera = np.linalg.inv(camera_pose)
        views.append(prepare(image, k, camera))
        seeds.extend(camera @ pose for pose in pose_seeds(image, k, DEFAULT_DIMENSIONS, camera_pose[:3, 1]))
        ok, jpeg = cv2.imencode('.jpg', image)
        assert ok
        frames.append({'capture_id': str(index), 'jpeg_base64': base64.b64encode(jpeg).decode(),
                       'width': 640, 'height': 640, 'K': k.tolist(), 'rectified': True,
                       'camera_up': camera_pose[:3, 1].tolist(), 'world_from_camera': camera.tolist()})
    return views, seeds, frames


class MultiViewTests(TestCase):
    def test_occluded_views_solve_jointly_when_each_closed_hull_detector_fails(self):
        views, seeds, frames = sequence()
        for frame in frames:
            image = cv2.imdecode(np.frombuffer(base64.b64decode(frame['jpeg_base64']), np.uint8), cv2.IMREAD_COLOR)
            self.assertEqual(estimate_cuboid(image, np.asarray(frame['K']), DEFAULT_DIMENSIONS,
                                             frame['camera_up'])['status'], 'not_found')
        result = run_job({'schema_version': 1, 'request_id': 'multi-view', 'mode': 'live',
                          'model_kind': 'cuboid', 'dimensions_m': list(DEFAULT_DIMENSIONS),
                          'physical_scale': 1, 'multiview': True, 'frames': frames}, Path('missing-assets'))
        self.assertEqual(result['status'], 'candidate', result.get('multiview_fit'))
        pose = np.asarray(result['multiview_fit']['world_from_model'])
        np.testing.assert_allclose(pose[:3, 3], 0, atol=.025)
        np.testing.assert_allclose(pose[:3, :3], np.eye(3), atol=.03)
        self.assertEqual(result['multiview_fit']['support_indices'], [0, 1, 2])
        self.assertTrue(all(row.get('overlay_jpeg_base64') for row in result['frames']))
        self.assertFalse(result['automatic_application_allowed'])

    def test_static_repeats_and_rotation_only_do_not_create_viewpoint_baseline(self):
        views, seeds, _ = sequence(False)
        self.assertEqual(fit([views[0]] * 3, seeds, DEFAULT_DIMENSIONS)['reason'], 'insufficient_baseline')
        self.assertEqual(fit([views[0], views[1], views[0]], seeds, DEFAULT_DIMENSIONS)['status'], 'rejected')
        for view in views:
            view['camera'][:3, 3] = views[0]['camera'][:3, 3]
        self.assertEqual(fit(views, seeds, DEFAULT_DIMENSIONS)['reason'], 'insufficient_baseline')

    def test_blank_views_cannot_be_explained_by_a_seed(self):
        views, _, _ = sequence(False)
        for view in views:
            view['distance'][:] = 100
        self.assertEqual(fit(views, [np.eye(4)], DEFAULT_DIMENSIONS)['status'], 'rejected')

    def test_camera_transforms_must_be_finite_rigid(self):
        for invalid in [np.eye(3), np.eye(4) * 2, np.full((4, 4), np.nan)]:
            with self.assertRaises(ValueError):
                rigid(invalid)

    def test_flat_panel_and_wrong_metric_dimensions_rejected(self):
        views, seeds, _ = sequence(False)
        self.assertEqual(fit(views, seeds, np.asarray(DEFAULT_DIMENSIONS) * 1.4)['status'], 'rejected')
        views = []
        for yaw in [25, 35, 45]:
            image, k, pose = scene(DEFAULT_DIMENSIONS, yaw)
            image[:] = 35
            pixels, _ = _project(corners(DEFAULT_DIMENSIONS)[:4], pose, k)
            cv2.fillConvexPoly(image, np.rint(pixels).astype('int32'), (200, 200, 200))
            views.append(prepare(image, k, np.linalg.inv(pose)))
        self.assertEqual(fit(views, [np.eye(4)], DEFAULT_DIMENSIONS)['status'], 'rejected')
