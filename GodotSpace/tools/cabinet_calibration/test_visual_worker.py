import base64
import json
from copy import deepcopy
from pathlib import Path
import tempfile
from unittest import TestCase, mock

import cv2
import numpy as np
import trimesh

import visual_pose_worker as worker


def frame(identifier="1"):
    ok, jpeg = cv2.imencode(".jpg", np.zeros((32, 48, 3), np.uint8))
    assert ok
    return {"capture_id": identifier, "jpeg_base64": base64.b64encode(jpeg).decode(),
            "width": 48, "height": 32, "K": [[50, 0, 24], [0, 50, 16], [0, 0, 1]],
            "rectified": True}


class VisualWorkerTests(TestCase):
    def test_progress_is_an_independent_processed_prefix(self):
        mesh = trimesh.creation.box()
        request = dict(schema_version=1, request_id='progress', mode='live',
                       model_kind='cad', physical_scale=1, frames=[frame(str(i)) for i in range(4)])
        snapshots = []
        prediction = dict(status='candidate', candidates=[dict(camera_from_model=np.eye(4).tolist())])
        with mock.patch.object(worker, 'load_assets', return_value=(
                dict(backend='test', model_sha256='test'), dict(print_scale=1, coordinate_system='test'), mesh)), \
                mock.patch.object(worker, 'estimate', return_value=prediction):
            result = worker.run_job(request, Path('unused'), lambda value: snapshots.append(deepcopy(value)))
        self.assertEqual([len(s['frames']) for s in snapshots], [1, 2, 3, 4])
        self.assertEqual([s['status'] for s in snapshots], ['rejected', 'rejected', 'candidate', 'candidate'])
        self.assertTrue(all(s['partial'] and s['total_frames'] == 4 for s in snapshots))
        self.assertNotIn('partial', result)
        self.assertEqual(result['frames'], snapshots[-1]['frames'])

    def test_noisy_preview_is_bounded_for_a_full_sequence(self):
        image = np.random.default_rng(3).integers(0, 256, (2048, 2048, 3), dtype=np.uint8)
        encoded = worker.overlay(image, np.empty((0, 3)), np.eye(4), np.eye(3))
        jpeg = base64.b64decode(encoded)
        self.assertLessEqual(len(jpeg), 512 * 1024)
        preview = cv2.imdecode(np.frombuffer(jpeg, np.uint8), cv2.IMREAD_COLOR)
        self.assertLessEqual(max(preview.shape[:2]), 960)

    def test_sequence_survives_missing_frames_and_retains_per_frame_previews(self):
        from test_cuboid_pose import scene
        image, k, pose = scene()
        frames = []
        # Real image geometry, including pale images and intermittent loss.
        for i in range(16):
            pixels = (image.astype(float) * .3 + 150).astype('uint8') if i % 2 else image
            if i in [0, 3, 7, 11, 15]:
                pixels = np.full_like(image, 180)
            ok, jpeg = cv2.imencode('.jpg', pixels)
            self.assertTrue(ok)
            frames.append({"capture_id": str(i), "jpeg_base64": base64.b64encode(jpeg).decode(),
                           "width": 640, "height": 640, "K": k.tolist(), "rectified": True,
                           "camera_up": pose[:3, 1].tolist()})
        request = {"schema_version": 1, "request_id": "sequence", "mode": "live",
                   "model_kind": "cuboid", "physical_scale": 1,
                   "dimensions_m": [.45, 1.21, .8], "frames": frames}
        result = worker.run_job(request, Path('missing-cad-assets'))
        self.assertEqual(result['status'], 'candidate')
        self.assertEqual(result['frame_counts'], {'candidate': 11, 'not_found': 5, 'ambiguous': 0})
        self.assertEqual([row['capture_id'] for row in result['frames']], [str(i) for i in range(16)])
        for row in result['frames']:
            self.assertEqual('overlay_jpeg_base64' in row, row['status'] == 'candidate')
        self.assertFalse(result['automatic_application_allowed'])
        request['frames'] = frames[:2]
        with self.assertRaisesRegex(ValueError, '3..16'):
            worker.run_job(request, Path('missing-cad-assets'))
        request['frames'] = frames + [frames[0]]
        with self.assertRaisesRegex(ValueError, '3..16'):
            worker.run_job(request, Path('missing-cad-assets'))

    def test_custom_demo_needs_no_cad_assets_and_cannot_apply(self):
        result = worker.run_job({"schema_version": 1, "request_id": "custom-demo", "mode": "demo",
                                 "model_kind": "cuboid", "physical_scale": 1,
                                 "dimensions_m": [.45, 1.21, .80]}, Path("missing-cad-assets"))
        self.assertEqual(result["status"], "candidate")
        self.assertEqual(result["model_kind"], "cuboid")
        self.assertGreaterEqual(result['timings_seconds']['job_seconds'], result['timings_seconds']['assets_seconds'])
        self.assertTrue(all(np.isfinite(value) and value >= 0 for value in result['timings_seconds'].values()))
        self.assertEqual(result["dimensions_m"], [.45, 1.21, .80])
        self.assertFalse(result["automatic_application_allowed"])
        self.assertTrue(result["overlay_jpeg_base64"])

    def test_custom_live_uses_image_geometry_and_reports_dimensions(self):
        from test_cuboid_pose import scene
        image, k, pose = scene((.7, 1.4, .5), -32)
        ok, jpeg = cv2.imencode('.jpg', image)
        self.assertTrue(ok)
        frames = [{"capture_id": str(i), "jpeg_base64": base64.b64encode(jpeg).decode(),
                   "width": 640, "height": 640, "K": k.tolist(), "rectified": True,
                   "camera_up": pose[:3, 1].tolist()} for i in range(3)]
        request = {"schema_version": 1, "request_id": "custom-live", "mode": "live",
                   "model_kind": "cuboid", "physical_scale": 1,
                   "dimensions_m": [.7, 1.4, .5], "frames": frames}
        result = worker.run_job(request, Path('missing-cad-assets'))
        self.assertEqual(result['status'], 'candidate')
        self.assertEqual(len(result['frames']), 3)
        request['physical_scale'] = 1 / 3
        with self.assertRaisesRegex(ValueError, 'already physical'):
            worker.run_job(request, Path('missing-cad-assets'))

    def test_wrong_model_bank_pair_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "templates").mkdir()
            (root / "assembly").mkdir()
            (root / "templates/templates.json").write_text(json.dumps({"model_sha256": "wrong"}))
            (root / "assembly/assembly_report.json").write_text(json.dumps({"model_sha256": "wrong"}))
            (root / "assembly/printed_assembly.ply").write_bytes(b"other CAD")
            with self.assertRaisesRegex(ValueError, "do not match"):
                worker.load_assets(root)

    def test_rejects_wrong_camera_image_pair_and_raw(self):
        for field, value in [("width", 64), ("rectified", False), ("jpeg_base64", "bad!")]:
            bad = frame()
            bad[field] = value
            with self.assertRaises(ValueError):
                worker.decode_frame(bad)

    def test_rejects_nan_and_non_pinhole_matrix(self):
        for matrix in [[[float("nan"), 0, 24], [0, 50, 16], [0, 0, 1]],
                       [[50, 2, 24], [0, 50, 16], [0, 0, 1]]]:
            bad = frame()
            bad["K"] = matrix
            with self.assertRaises(ValueError):
                worker.decode_frame(bad)

    @mock.patch.object(worker, "load_assets")
    @mock.patch.object(worker, "estimate")
    def test_scale_changes_metric_translation_and_model_not_pixel_fit(self, estimate, assets):
        assets.return_value = ({"model_sha256": "a" * 64, "backend": "test"},
                               {"print_scale": 1 / 3, "coordinate_system": "godot_frame_mesh_local_right_handed_y_up"},
                               trimesh.creation.box(extents=[0.3, 0.6, 0.4]))
        pose = np.eye(4)
        pose[2, 3] = 1
        estimate.return_value = {"status": "candidate", "candidates": [{
            "camera_from_model": pose.tolist(), "inliers": 20, "reprojection_rms_px": 1}]}
        request = {"schema_version": 1, "request_id": "test", "mode": "live", "physical_scale": 1,
                   "frames": [frame(str(i)) for i in range(3)]}
        result = worker.run_job(request, Path("unused"))
        self.assertEqual(result["status"], "candidate")
        self.assertEqual(result["frames"][0]["camera_from_model"][2][3], 3)
        np.testing.assert_allclose(result["model_extents_m"], [0.9, 1.8, 1.2])
        self.assertFalse(result["automatic_application_allowed"])
        estimate.return_value = {"status": "ambiguous", "candidates": []}
        rejected = worker.run_job(request, Path("unused"))
        self.assertEqual(rejected["status"], "rejected")
        self.assertNotIn("camera_from_model", rejected["frames"][0])
        duplicate = deepcopy(request)
        duplicate["frames"][2] = duplicate["frames"][0]
        with self.assertRaisesRegex(ValueError, "Repeated"):
            worker.run_job(duplicate, Path("unused"))

    def test_invalid_request_rejected_before_assets(self):
        for scale in (float("nan"), 0, -1, 5):
            with self.assertRaises(ValueError):
                worker.run_job({"schema_version": 1, "request_id": "bad", "mode": "live",
                                "physical_scale": scale}, Path("missing"))
