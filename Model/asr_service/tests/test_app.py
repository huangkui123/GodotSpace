from __future__ import annotations

import struct
import asyncio
import unittest

from fastapi.testclient import TestClient

from asr_service.app import create_app, _let_client_close


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
            self.assertEqual(final["endpoint_reason"], "input_idle_timeout")
            self.assertEqual(websocket.receive_json()["type"], "finished")

    def test_rejects_wrong_audio_format(self) -> None:
        with self.client.websocket_connect("/ws/asr") as websocket:
            websocket.send_json(
                {"type": "start", "sample_rate": 48_000, "format": "float32"}
            )
            error = websocket.receive_json()
            self.assertEqual(error["type"], "error")

    def test_empty_watchdog_result_still_clears_client_cursor(self) -> None:
        engine = FakeEngine()
        engine.recognize = lambda *args, **kwargs: ""
        client = TestClient(create_app(engine))
        with client.websocket_connect("/ws/asr") as websocket:
            websocket.send_json({"type": "start", "sample_rate": 16000,
                                 "format": "pcm_s16le", "need_vad": False,
                                 "stable_partial_msec": 1000})
            self.assertEqual(websocket.receive_json()["type"], "ready")
            websocket.send_bytes(pcm(4000, 100))
            self.assertEqual(websocket.receive_json()["type"], "finished")


class FinalHandshakeTests(unittest.IsolatedAsyncioTestCase):
    async def test_inflight_audio_is_not_a_final_acknowledgement(self):
        class Socket:
            count = 0
            closed = False

            async def receive(self):
                self.count += 1
                await asyncio.sleep(0)
                return {"type": "websocket.receive", "bytes": pcm(0)} if self.count < 4 else {"type": "websocket.disconnect"}

            async def close(self, **kwargs):
                self.closed = True

        socket = Socket()
        await _let_client_close(socket)
        self.assertEqual(socket.count, 4)
        self.assertFalse(socket.closed)

    async def test_unresponsive_client_still_has_bounded_cleanup(self):
        class Socket:
            closed = False

            async def receive(self):
                await asyncio.Event().wait()

            async def close(self, **kwargs):
                self.closed = True

        socket = Socket()
        await asyncio.wait_for(_let_client_close(socket), timeout=3)
        self.assertTrue(socket.closed)


if __name__ == "__main__":
    unittest.main()
