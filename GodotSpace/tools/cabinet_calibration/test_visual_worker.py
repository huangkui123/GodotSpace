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
