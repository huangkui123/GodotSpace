import io
import json
from pathlib import Path
import tempfile
import unittest
import zipfile

import cv2
import numpy as np
from scipy.spatial.transform import Rotation
import trimesh

from geometry import axis_rotations, rigid_fit, transform_points, icp, sample_surface
from magics_mesh import open_mt_archive, convert
from prepare_model import inspect_stl
from render_model import camera_pose, render
from rgb_pose import fit_correspondences, load_camera, estimate


class GeometryTests(unittest.TestCase):
    def test_rigid_fit_recovers_rotation_translation_without_scaling(self):
        rng = np.random.default_rng(2)
        points = rng.normal(size=(80, 3))
        expected = np.eye(4)
        expected[:3, :3] = Rotation.from_euler("xyz", [31, -17, 8], degrees=True).as_matrix()
        expected[:3, 3] = [1.2, -0.7, 0.8]
        actual = rigid_fit(points, transform_points(points, expected))
        np.testing.assert_allclose(actual, expected, atol=1e-10)

    def test_reflections_cannot_become_rigid_rotations(self):
        points = np.random.default_rng(3).normal(size=(80, 3))
        target = points * [-1, 1, 1]
        fitted = rigid_fit(points, target)
        self.assertAlmostEqual(np.linalg.det(fitted[:3, :3]), 1.0)
        self.assertGreater(np.mean((transform_points(points, fitted) - target) ** 2), 0.1)

    def test_axis_seeds_are_24_distinct_proper_rotations(self):
        matrices = axis_rotations()
        self.assertEqual(len({m.tobytes() for m in matrices}), 24)
        for matrix in matrices:
            self.assertAlmostEqual(np.linalg.det(matrix), 1)

    def test_icp_tolerates_partial_source_outliers(self):
        points = np.random.default_rng(6).normal(size=(900, 3)) * [0.2, 0.3, 0.1]
        expected = np.eye(4)
        expected[:3, :3] = Rotation.from_euler("y", 4, degrees=True).as_matrix()
        expected[:3, 3] = [0.008, -0.01, 0.005]
        target = transform_points(points, expected)
        source = np.vstack([points, [[5, 5, 5]] * 50])
        actual = icp(source, target, np.eye(4))
        np.testing.assert_allclose(actual, expected, atol=1e-5)

    def test_sampling_reproducible_and_stl_inventory(self):
        box = trimesh.creation.box(extents=[1, 2, 3])
        np.testing.assert_array_equal(sample_surface(box, 100), sample_surface(box, 100))
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "box.stl"
            box.export(path)
            row = inspect_stl(path)
            self.assertEqual(row["triangles"], 12)
            np.testing.assert_allclose(row["extents_source_units"], [1, 2, 3])


class MagicsTests(unittest.TestCase):
    @staticmethod
    def archive_bytes(vertices=None, faces=None):
        if vertices is None:
            vertices = np.array([[0, 0, 0], [10000000, 0, 0], [0, 10000000, 0]], dtype="<i4")
        if faces is None:
            faces = np.array([[0, 1, 2]], dtype="<i4")
        stream = io.BytesIO()
        with zipfile.ZipFile(stream, "w", zipfile.ZIP_DEFLATED) as archive:
            archive.writestr("Stl(1)_vertices", vertices.tobytes())
            archive.writestr("Stl(1)_surfaces", faces.tobytes())
            archive.writestr("header.xml", b"opaque metadata")
        data = stream.getvalue()
        for signature in (b"\x03\x04", b"\x01\x02", b"\x05\x06"):
            data = data.replace(b"PK" + signature, b"MT" + signature)
        return data

    def test_geometry_units_and_index_decode(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "test.magics"
            path.write_bytes(self.archive_bytes())
            result = convert(path, Path(directory) / "out")
            self.assertFalse(result["metadata_decoded"])
            np.testing.assert_allclose(result["parts"][0]["extents_m"], [1, 1, 0])
            self.assertEqual(result["parts"][0]["triangles"], 1)

    def test_rejects_invalid_vertex_indices(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "test.magics"
            path.write_bytes(self.archive_bytes(faces=np.array([[0, 1, 7]], dtype="<i4")))
            with self.assertRaisesRegex(ValueError, "indices"):
                convert(path, Path(directory) / "out")

    def test_rejects_truncated_container(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "test.magics"
            path.write_bytes(self.archive_bytes()[:-5])
            with self.assertRaises(ValueError):
                open_mt_archive(path)

    def test_crc_is_checked(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "test.magics"
            data = bytearray(self.archive_bytes())
            # Deliberately invalidate the authoritative CRC in the central entry.
            offset = data.index(b"MT\x01\x02")
            data[offset + 16] ^= 1
            path.write_bytes(data)
            with open_mt_archive(path) as archive:
                with self.assertRaises(zipfile.BadZipFile):
                    archive.read("Stl(1)_vertices")


class VisionTests(unittest.TestCase):
    def setUp(self):
        self.k = np.array([[760, 0, 320], [0, 755, 240], [0, 0, 1]], dtype=float)
        self.distortion = np.zeros(5)

    def test_pose_with_noise_and_wrong_correspondences(self):
        rng = np.random.default_rng(8)
        points = rng.uniform(-0.15, 0.15, (65, 3))
        rvec = np.array([0.16, -0.23, 0.08])
        translation = np.array([0.03, 0.02, 0.9])
        pixels = cv2.projectPoints(points, rvec, translation, self.k, self.distortion)[0].reshape(-1, 2)
        pixels += rng.normal(0, 0.25, pixels.shape)
        pixels[:12] = rng.uniform([20, 20], [620, 460], (12, 2))
        result = fit_correspondences(points, pixels, self.k, self.distortion)
        self.assertIsNotNone(result)
        actual = np.array(result["camera_from_model"])
        self.assertLess(np.linalg.norm(actual[:3, 3] - translation), 0.002)
        self.assertLess(Rotation.from_matrix(cv2.Rodrigues(rvec)[0].T @ actual[:3, :3]).magnitude(), 0.01)

    def test_repeated_or_collinear_points_rejected(self):
        points = np.array([[x, 0, 0] for x in np.linspace(-0.2, 0.2, 30)])
        pixels = cv2.projectPoints(points, np.zeros(3), np.array([0., 0., 1.]),
                                  self.k, self.distortion)[0].reshape(-1, 2)
        self.assertIsNone(fit_correspondences(points, pixels, self.k, self.distortion))
        self.assertIsNone(fit_correspondences(np.zeros((30, 3)), pixels, self.k, self.distortion))

    def test_camera_resolution_mismatch_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "camera.json"
            path.write_text(json.dumps({"width": 640, "height": 480, "K": self.k.tolist(),
                                        "distortion": [0, 0, 0, 0, 0]}))
            with self.assertRaisesRegex(ValueError, "resolution"):
                load_camera(path, (720, 1280, 3))
            matrix, _ = load_camera(path, (480, 640, 3))
            np.testing.assert_array_equal(matrix, self.k)

    def test_blank_image_is_not_a_detection(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)
            (path / "templates.json").write_text(json.dumps({
                "backend": "test", "model_sha256": "none", "templates": []}))
            result = estimate(np.zeros((480, 640, 3), np.uint8), self.k, self.distortion, path)
            self.assertEqual(result["status"], "not_found")
            self.assertFalse(result["runtime_application_allowed"])

    def test_rasterized_xyz_reprojects_to_original_pixel(self):
        box = trimesh.creation.box(extents=[0.2, 0.4, 0.15])
        pose = camera_pose(np.zeros(3), 0.7, 35, 20)
        k = np.array([[100, 0, 64], [0, 100, 64], [0, 0, 1.]])
        _, xyz = render(box, pose, k, (128, 128))
        yy, xx = np.where(np.isfinite(xyz).all(axis=2))
        self.assertGreater(len(xx), 500)
        p = transform_points(xyz[yy, xx], pose) @ k.T
        projected = p[:, :2] / p[:, 2:]
        np.testing.assert_allclose(projected, np.column_stack([xx, yy]), atol=1e-4)


if __name__ == "__main__":
    unittest.main()
