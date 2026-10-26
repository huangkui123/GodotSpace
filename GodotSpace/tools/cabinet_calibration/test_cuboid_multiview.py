import base64
import json
from pathlib import Path
from unittest import TestCase

import cv2
import numpy as np

from cuboid_faces import pose_seeds, partial_pose_seeds
from cuboid_multiview import fit, prepare, rigid
from cuboid_pose import DEFAULT_DIMENSIONS, estimate_cuboid, corners, _project, FACES
from test_cuboid_pose import scene
from render_model import camera_pose as render_camera_pose
from visual_pose_worker import run_job


def sequence(occluded=True, timed=False):
    views, seeds, frames = [], [], []
    rng = np.random.default_rng(42)
    texture = np.full((512, 512, 3), 35, np.uint8)
    for _ in range(350):
        center = tuple(rng.integers(0, 512, 2).tolist())
        shade = int(rng.integers(80, 230))
        cv2.circle(texture, center, int(rng.integers(2, 8)), (shade,) * 3, -1)
    for index, yaw in enumerate([25, 35, 45]):
        image, k, camera_pose = scene(DEFAULT_DIMENSIONS, yaw)
        if timed:
            # A static textured wall behind the cabinet supplies independently
            # tracked features. It is projected from the same 3D plane in every
            # view; it is not a screen-space texture glued to the moving camera.
            wall = np.array([[-3, 4, -1.5], [3, 4, -1.5], [3, -1, -1.5], [-3, -1, -1.5]])
            pixels, _ = _project(wall, camera_pose, k)
            homography = cv2.getPerspectiveTransform(np.float32([[0, 0], [511, 0], [511, 511], [0, 511]]),
                                                     pixels.astype('float32'))
            background = cv2.warpPerspective(texture, homography, (640, 640))
            mask = np.any(image != 35, axis=2)
            background[mask] = image[mask]
            image = background
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
        if timed:
            paths = []
            for delay in range(0, 401, 10):
                pose = render_camera_pose(corners(DEFAULT_DIMENSIONS).mean(0), max(DEFAULT_DIMENSIONS) * 2.4,
                                          yaw + [8, -12, 6][index] * (.12 - delay / 1000), 18)
                paths.append(np.linalg.inv(pose).tolist())
            frames[-1]['camera_history'] = paths
            frames[-1]['world_from_camera'] = paths[0]
            frames[-1]['camera_up'] = np.array(paths[0])[:3, :3].T[:, 1].tolist()
    return views, seeds, frames


class MultiViewTests(TestCase):
    def test_clipped_bottom_generates_metric_seeds_without_a_closed_face(self):
        image, k, truth = scene(DEFAULT_DIMENSIONS, 35)
        cropped = image[:380]
        seeds = partial_pose_seeds(cropped, k, DEFAULT_DIMENSIONS, truth[:3, 1])
        self.assertTrue(seeds)
        center = corners(DEFAULT_DIMENSIONS).mean(0)
        error = min(np.linalg.norm(seed[:3, :3] @ center + seed[:3, 3]
                                   - truth[:3, :3] @ center - truth[:3, 3]) for seed in seeds)
        self.assertLess(error, .04)

    def test_door_seam_and_partial_floor_lines_do_not_shift_the_box_down(self):
        views = []
        wrong = np.eye(4)
        wrong[1, 3] = -.16
        points = corners(DEFAULT_DIMENSIONS)
        for yaw in [25, 35, 45]:
            image, k, camera_pose = scene(DEFAULT_DIMENSIONS, yaw)
            # Strong internal seam and unrelated partial lines on the floor
            # form most, but not all, of a second translated cuboid outline.
            for face in [FACES[0], FACES[5]]:
                for a, b in zip(face, face[1:] + face[:1]):
                    if abs(points[a, 1] - points[b, 1]) > .01:
                        continue
                    end = points[b] if points[a, 1] > 0 else points[a] * .3 + points[b] * .7
                    uv, _ = _project(np.array([points[a], end]), camera_pose @ wrong, k)
                    cv2.line(image, tuple(np.rint(uv[0]).astype(int)), tuple(np.rint(uv[1]).astype(int)),
                             (80, 80, 80), 2)
            views.append(prepare(image, k, np.linalg.inv(camera_pose)))
        result = fit(views, [wrong, np.eye(4)], DEFAULT_DIMENSIONS)
        self.assertEqual(result['status'], 'candidate', result)
        np.testing.assert_allclose(np.asarray(result['world_from_model'])[:3, 3], 0, atol=.025)

    def test_image_matches_correct_delay_before_joint_cabinet_fit(self):
        _, _, frames = sequence(timed=True)
        result = run_job({'schema_version': 1, 'request_id': 'timed-views', 'mode': 'live',
                          'model_kind': 'cuboid', 'dimensions_m': list(DEFAULT_DIMENSIONS),
                          'physical_scale': 1, 'multiview': True, 'frames': frames,
                          'pose_timing': 'interpolated_arrival_estimate'}, Path('missing-assets'))
        self.assertEqual(result['camera_timing']['status'], 'verified', result.get('camera_timing'))
        self.assertLessEqual(abs(result['camera_timing']['delay_ms'] - 120), 20)
        self.assertEqual(result['status'], 'candidate', result.get('multiview_fit'))
        np.testing.assert_allclose(np.asarray(result['multiview_fit']['world_from_model'])[:3, 3], 0, atol=.025)

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
        self.assertGreater(len(result['multiview_fit']['diagnostics']['trials']), 0)
        json.dumps(result, allow_nan=False)  # Full evidence must cross the worker's JSON boundary.

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
        rejected = fit(views, [np.eye(4)], DEFAULT_DIMENSIONS)
        self.assertEqual(rejected['status'], 'rejected')
        self.assertEqual(rejected['diagnostics']['trials'][0]['supported_view_indices'], [])
        json.dumps(rejected, allow_nan=False)

    def test_camera_transforms_must_be_finite_rigid(self):
        for invalid in [np.eye(3), np.eye(4) * 2, np.full((4, 4), np.nan)]:
            with self.assertRaises(ValueError):
                rigid(invalid)

    def test_complementary_crops_do_not_require_a_full_face_in_every_view(self):
        views = []
        for yaw, crop in [(25, (230, 640, 0, 640)), (35, (0, 430, 0, 640)),
                          (45, (0, 640, 0, 380))]:
            image, k, pose = scene(DEFAULT_DIMENSIONS, yaw)
            top, bottom, left, right = crop
            k[0, 2] -= left
            k[1, 2] -= top
            views.append(prepare(image[top:bottom, left:right], k, np.linalg.inv(pose)))
        result = fit(views, [np.eye(4)], DEFAULT_DIMENSIONS)
        self.assertEqual(result['status'], 'candidate', result)
        np.testing.assert_allclose(np.asarray(result['world_from_model'])[:3, 3], 0, atol=.025)

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
