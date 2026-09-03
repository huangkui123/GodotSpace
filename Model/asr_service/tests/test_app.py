from __future__ import annotations

import struct
import unittest

from fastapi.testclient import TestClient

from asr_service.app import create_app


class FakeEngine:
    loaded = True
    model_name = "fake-streaming"
    device = "test"
    load_error = ""

    def create_session(self, hotwords: str = "") -> dict[str, object]:
        return {"hotwords": hotwords}

    def recognize(self, session: dict[str, object], audio: bytes, *, is_final: bool) -> str:
        return "智能助手打开工作清单" if is_final else "智能助手"


def pcm(value: int, milliseconds: int = 200) -> bytes:
    samples = 16_000 * milliseconds // 1000
    return struct.pack(f"<{samples}h", *([value] * samples))


class LocalAsrAppTests(unittest.TestCase):
    def setUp(self) -> None:
        self.client = TestClient(create_app(FakeEngine()))

    def test_health(self) -> None:
        response = self.client.get("/health")
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.json()["status"], "ready")

    def test_websocket_stream_and_finish(self) -> None:
        with self.client.websocket_connect("/ws/asr") as websocket:
            websocket.send_json(
                {
                    "type": "start",
                    "sample_rate": 16_000,
                    "format": "pcm_s16le",
                    "need_vad": False,
                }
            )
            self.assertEqual(websocket.receive_json()["type"], "ready")
            for _ in range(3):
                websocket.send_bytes(pcm(4000))
            partial = websocket.receive_json()
            self.assertEqual(partial["type"], "transcript")
            self.assertFalse(partial["is_final"])
            websocket.send_json({"type": "finish"})
            final = websocket.receive_json()
            self.assertTrue(final["is_final"])
            self.assertEqual(final["text"], "智能助手打开工作清单")
            self.assertEqual(websocket.receive_json()["type"], "finished")

    def test_websocket_watchdog_finishes_when_audio_packets_stop(self) -> None:
        with self.client.websocket_connect("/ws/asr") as websocket:
            websocket.send_json(
                {
                    "type": "start",
                    "sample_rate": 16_000,
                    "format": "pcm_s16le",
                    "need_vad": False,
                    "stable_partial_msec": 1000,
                }
            )
            self.assertEqual(websocket.receive_json()["type"], "ready")
            websocket.send_bytes(pcm(4000, 600))
            partial = websocket.receive_json()
            self.assertFalse(partial["is_final"])

            final = websocket.receive_json()
            self.assertTrue(final["is_final"])
            self.assertEqual(final["endpoint_reason"], "stable_partial_wall_timeout")
            self.assertEqual(websocket.receive_json()["type"], "finished")

    def test_rejects_wrong_audio_format(self) -> None:
        with self.client.websocket_connect("/ws/asr") as websocket:
            websocket.send_json(
                {"type": "start", "sample_rate": 48_000, "format": "float32"}
            )
            error = websocket.receive_json()
            self.assertEqual(error["type"], "error")


if __name__ == "__main__":
    unittest.main()
