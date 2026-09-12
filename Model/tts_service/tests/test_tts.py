from __future__ import annotations

import asyncio
import threading
import unittest

import httpx

from tts_service.app import create_app
from tts_service.engine import normalize_text


class FakeEngine:
    loaded = True

    def load(self):
        pass

    def synthesize(self, text):
        return b"\x01\x00" * 80, 8000


class TtsTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.app = create_app(FakeEngine())
        self.client = httpx.AsyncClient(transport=httpx.ASGITransport(app=self.app), base_url="http://test")

    async def asyncTearDown(self):
        await self.client.aclose()

    async def test_health_and_pcm(self):
        self.assertEqual((await self.client.get("/health")).json()["device"], "cpu")
        response = await self.client.post("/v1/speech", json={"text": "工作清单已打开。"})
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.headers["x-sample-rate"], "8000")
        self.assertEqual(response.headers["x-audio-format"], "pcm_s16le")
        self.assertEqual(len(response.content), 160)

    async def test_validation(self):
        for data in [[], {}, {"text": ""}, {"text": 2}, {"text": "a" * 501},
                     {"text": "测试", "path": "/tmp/x"}, {"text": "测试", "speaker": 9999}]:
            with self.subTest(data=str(data)[:60]):
                self.assertEqual((await self.client.post("/v1/speech", json=data)).status_code, 422)
        self.assertEqual((await self.client.post("/v1/speech", content=b"{")).status_code, 400)
        self.assertEqual((await self.client.post("/v1/speech", content=b"a" * 5000)).status_code, 413)
        self.assertEqual((await self.client.post("/v1/speech", json={"text": "测试"},
                                               headers={"Origin": "https://example.com"})).status_code, 403)

    async def test_not_ready(self):
        self.app.state.engine.loaded = False
        self.assertEqual((await self.client.post("/v1/speech", json={"text": "测试"})).status_code, 503)

    async def test_failure_releases_slot(self):
        def fail(text):
            raise RuntimeError("private path")
        self.app.state.engine.synthesize = fail
        response = await self.client.post("/v1/speech", json={"text": "测试"})
        self.assertEqual(response.status_code, 503)
        self.assertNotIn("private", response.text)
        self.assertFalse(self.app.state.busy)

    async def test_cancel_does_not_release_native_worker(self):
        entered, release = threading.Event(), threading.Event()
        def block(text):
            entered.set()
            release.wait(3)
            return b"\x01\x00", 8000
        self.app.state.engine.synthesize = block
        request = asyncio.create_task(self.client.post("/v1/speech", json={"text": "测试"}))
        try:
            await asyncio.to_thread(entered.wait, 2)
            self.assertTrue(entered.is_set())
            request.cancel()
            with self.assertRaises(asyncio.CancelledError):
                await request
            self.assertTrue(self.app.state.busy)
            self.assertEqual((await self.client.post("/v1/speech", json={"text": "新请求"})).status_code, 429)
        finally:
            release.set()
            if self.app.state.active_task:
                await self.app.state.active_task
        self.assertFalse(self.app.state.busy)

    def test_numeric_units_preserved(self):
        self.assertEqual(normalize_text("**不要超过 25 N·m，间隙 2.5 mm。**"),
                         "不要超过 25 牛顿米，间隙 2.5毫米。")


if __name__ == "__main__":
    unittest.main()
