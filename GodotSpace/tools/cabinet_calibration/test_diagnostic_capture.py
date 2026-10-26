import json
from pathlib import Path
import subprocess
import sys
import tempfile
from unittest import TestCase

from diagnostic_capture import save_case
from test_visual_worker import frame


class DiagnosticCaptureTests(TestCase):
    def test_last_live_case_survives_demo_and_failed_write(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'last_scan.json'
            self.assertEqual(save_case(path, {'mode': 'live', 'request_id': 'first'}, {'status': 'rejected'}), str(path))
            first = path.read_bytes()
            self.assertIsNone(save_case(path, {'mode': 'demo'}, {}))
            self.assertEqual(path.read_bytes(), first)
            self.assertIsNone(save_case(path, {'mode': 'live', 'bad': float('nan')}, {}))
            self.assertEqual(path.read_bytes(), first)
            save_case(path, {'mode': 'live', 'request_id': 'second'}, {'status': 'candidate'})
            self.assertEqual(json.loads(path.read_text())['request']['request_id'], 'second')
            self.assertEqual(sorted(p.name for p in path.parent.iterdir()), ['last_scan.json', 'last_scan.lock'])

    def test_unwritable_destination_does_not_crash_recognition(self):
        with tempfile.TemporaryDirectory() as directory:
            obstruction = Path(directory) / 'file'
            obstruction.write_text('keep')
            self.assertIsNone(save_case(obstruction / 'last_scan.json', {'mode': 'live'}, {}))
            self.assertEqual(obstruction.read_text(), 'keep')

    def test_worker_replays_preserved_images_after_original_request_deleted(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            request = {'schema_version': 1, 'request_id': 'retained', 'mode': 'live', 'model_kind': 'cuboid',
                       'dimensions_m': [.45, 1.21, .8], 'physical_scale': 1,
                       'frames': [frame(str(i)) for i in range(3)]}
            for sample in request['frames']:
                sample['camera_up'] = [0, -1, 0]
            source, result, capture = root / 'request.json', root / 'result.json', root / 'last_scan.json'
            source.write_text(json.dumps(request))
            command = [sys.executable, '-B', str(Path(__file__).with_name('visual_pose_worker.py')),
                       '--artifacts', str(root / 'no-assets'), '--output', str(result), '--diagnostic', str(capture)]
            process = subprocess.run(command + ['--request', str(source)], timeout=30, capture_output=True)
            self.assertEqual(process.returncode, 0, result.read_text() if result.exists() else process.stderr)
            saved = capture.read_bytes()
            self.assertEqual(json.loads(saved)['request'], request)
            source.unlink()
            result.unlink()
            subprocess.run(command + ['--replay', str(capture)], check=True, timeout=30, capture_output=True)
            self.assertEqual(capture.read_bytes(), saved, 'Offline replay must preserve the field capture')
            self.assertEqual(json.loads(result.read_text())['status'], 'rejected')
