from unittest import TestCase

import cv2
import numpy as np

from cuboid_pose import DEFAULT_DIMENSIONS, corners, dimensions, estimate_cuboid, mesh_for
from render_model import camera_pose, render


def scene(size=DEFAULT_DIMENSIONS, yaw=35, elevation=18, background=35):
    mesh = mesh_for(size)
    k = np.array([[680., 0, 320], [0, 675., 320], [0, 0, 1.]])
    truth = camera_pose(mesh.bounds.mean(0), max(size) * 2.4, yaw, elevation)
    rgb, _ = render(mesh, truth, k, background=background, light=(-.3, -.7, -1))
    return cv2.cvtColor(rgb, cv2.COLOR_RGB2BGR), k, truth


class CuboidPoseTests(TestCase):
    def test_real_image_solver_recovers_custom_sizes_and_views(self):
        for size, yaw in [(DEFAULT_DIMENSIONS, 35), ((.7, 1.4, .5), -32), ((.6, .9, .8), 25), ((1, 1, 1), 30)]:
            with self.subTest(size=size, yaw=yaw):
                image, k, truth = scene(size, yaw)
                result = estimate_cuboid(image, k, size, truth[:3, 1])
                self.assertEqual(result['status'], 'candidate', result)
                recovered = np.asarray(result['candidates'][0]['camera_from_model'])
                center = corners(size).mean(0)
                np.testing.assert_allclose(recovered[:3, :3] @ center + recovered[:3, 3],
                                           truth[:3, :3] @ center + truth[:3, 3], atol=.025)
                self.assertLess(np.linalg.norm(recovered[:3, :3] - truth[:3, :3]), .08)

    def test_blank_rectangle_and_silhouette_without_junctions_rejected(self):
        image, k, truth = scene()
        blank = np.zeros_like(image)
        rectangle = blank.copy()
        cv2.rectangle(rectangle, (200, 120), (400, 550), (240, 240, 240), -1)
        solid_hull = blank.copy()
        gray = cv2.cvtColor(image, cv2.COLOR_BGR2GRAY)
        contours, _ = cv2.findContours((gray > 40).astype('uint8'), cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)
        cv2.fillConvexPoly(solid_hull, cv2.convexHull(max(contours, key=cv2.contourArea)), (230, 230, 230))
        for invalid in [blank, rectangle, solid_hull]:
            self.assertEqual(estimate_cuboid(invalid, k, DEFAULT_DIMENSIONS, truth[:3, 1])['status'], 'not_found')

    def test_bad_dimensions_and_tracking_up_rejected(self):
        for invalid in [(0, 1, 1), (1, float('nan'), 1), (1, 1), (1, 1, 21)]:
            with self.assertRaises(ValueError):
                dimensions(invalid)
        image, k, _ = scene()
        with self.assertRaises(ValueError):
            estimate_cuboid(image, k, DEFAULT_DIMENSIONS, [0, 0, 0])

    def test_contrast_and_noise(self):
        image, k, truth = scene()
        image = cv2.GaussianBlur(image, (3, 3), .5)
        image = np.clip(image.astype(float) + np.random.default_rng(42).normal(0, 1, image.shape), 0, 255).astype('uint8')
        result = estimate_cuboid(image, k, DEFAULT_DIMENSIONS, truth[:3, 1])
        self.assertEqual(result['status'], 'candidate')

    def test_pale_cabinet_preserves_geometry_after_contrast_enhancement(self):
        image, k, truth = scene()
        image = np.clip(image.astype(float) * .3 + 150, 0, 255).astype('uint8')
        result = estimate_cuboid(image, k, DEFAULT_DIMENSIONS, truth[:3, 1])
        self.assertEqual(result['status'], 'candidate')
        recovered = np.asarray(result['candidates'][0]['camera_from_model'])
        np.testing.assert_allclose(recovered[:3, 3], truth[:3, 3], atol=.025)
        self.assertLess(np.linalg.norm(recovered[:3, :3] - truth[:3, :3]), .08)
        # Amplifying local contrast must not turn sensor noise into a cabinet.
        noise = np.random.default_rng(13).normal(180, 2, image.shape).clip(0, 255).astype('uint8')
        self.assertEqual(estimate_cuboid(noise, k, DEFAULT_DIMENSIONS, truth[:3, 1])['status'], 'not_found')

    def test_multiple_matching_cabinets_are_ambiguous(self):
        mesh = mesh_for(DEFAULT_DIMENSIONS)
        k = np.array([[680., 0, 320], [0, 675., 320], [0, 0, 1.]])
        base = camera_pose(mesh.bounds.mean(0), 4.8, 35, 18)
        image = np.full((640, 640, 3), 35, np.uint8)
        for offset in (-.85, .85):
            pose = base.copy()
            pose[0, 3] += offset
            rgb, xyz = render(mesh, pose, k, background=35)
            mask = np.isfinite(xyz).all(axis=-1)
            image[mask] = cv2.cvtColor(rgb, cv2.COLOR_RGB2BGR)[mask]
        self.assertEqual(estimate_cuboid(image, k, DEFAULT_DIMENSIONS, base[:3, 1])['status'], 'ambiguous')
