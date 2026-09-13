from __future__ import annotations

import asyncio
import threading
import unittest
from unittest.mock import patch
import os
from types import SimpleNamespace
import numpy as np

import httpx

from tts_service.app import create_app
from tts_service.engine import normalize_text, SpeechEngine, MODEL_NAME, LEGACY_MODEL_NAME, CUDA_MODEL_NAME


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

    def test_markdown_without_changing_negative_numbers(self):
        self.assertEqual(normalize_text("## 限值\n- 不得超过 2.5 N·m。\n温度 -25℃。"),
                         "限值\n不得超过 2.5 牛顿米。\n温度 -25摄氏度。")
        self.assertEqual(normalize_text("- 25℃\n+ 10℃"), "- 25摄氏度\n+ 10摄氏度")

    def test_cpu_model_defaults_and_legacy_override(self):
        with patch.dict(os.environ, {}, clear=True):
            engine = SpeechEngine()
            self.assertEqual((engine.kind, engine.model_name, engine.speaker), ("kokoro", MODEL_NAME, 17))
            self.assertEqual(engine.threads, 2)
        with patch.dict(os.environ, {"LOCAL_TTS_MODEL": "vits"}, clear=True):
            engine = SpeechEngine()
            self.assertEqual((engine.model_name, engine.speaker), (LEGACY_MODEL_NAME, 66))
        with patch.dict(os.environ, {"LOCAL_TTS_MODEL_DIR": "/models/" + LEGACY_MODEL_NAME}, clear=True):
            self.assertEqual(SpeechEngine().kind, "vits")

    def test_bad_configuration_rejected(self):
        for env in [{"LOCAL_TTS_MODEL": "unknown"}, {"LOCAL_TTS_SPEED": "nan"},
                    {"LOCAL_TTS_DEVICE": "unknown"}, {"LOCAL_TTS_MODEL": "vits", "LOCAL_TTS_DEVICE": "cuda"},
                    {"LOCAL_TTS_SPEED": "0.1"}, {"LOCAL_TTS_SPEED": "2"}]:
            with self.subTest(env=env), patch.dict(os.environ, env, clear=True), self.assertRaises(ValueError):
                SpeechEngine()

    def test_kokoro_voice_override_preserved_on_cpu_and_cuda(self):
        for device in ("cpu", "cuda"):
            with self.subTest(device=device), patch.dict(os.environ, {
                "LOCAL_TTS_DEVICE": device, "LOCAL_TTS_SPEAKER": "3",
            }, clear=True):
                self.assertEqual(SpeechEngine().speaker, 3)

    def test_cuda_uses_full_precision_model_not_dynamic_int8(self):
        with patch.dict(os.environ, {"LOCAL_TTS_DEVICE": "cuda"}, clear=True):
            engine = SpeechEngine()
            self.assertEqual(engine.device, "cuda")
            self.assertEqual(engine.model_name, CUDA_MODEL_NAME)
            self.assertEqual(engine.model_file, "model.onnx")
            self.assertEqual(engine.speaker, 17)

    def test_cuda_rejects_cpu_wheel_instead_of_silent_fallback(self):
        from tts_service.cuda_runtime import prepare_cuda
        with patch("tts_service.cuda_runtime.version", return_value="1.13.8"):
            with self.assertRaisesRegex(RuntimeError, "CUDA wheel"):
                prepare_cuda()

    def test_missing_model_does_not_download(self):
        with patch.dict(os.environ, {"LOCAL_TTS_MODEL_DIR": "/does-not-exist-tts-test"}, clear=True):
            with self.assertRaisesRegex(RuntimeError, "model missing"):
                SpeechEngine().load()

    def test_cache_is_bounded_and_voice_sensitive(self):
        with patch.dict(os.environ, {}, clear=True):
            engine = SpeechEngine()
        calls = []
        def generate(text, sid, speed):
            calls.append((text, sid, speed))
            return SimpleNamespace(samples=np.ones(80) * 0.1, sample_rate=24000)
        engine._tts = SimpleNamespace(generate=generate)
        self.assertEqual(engine.synthesize("测试"), engine.synthesize("测试"))
        self.assertEqual(len(calls), 1)
        engine.speaker = 9
        engine.synthesize("测试")
        self.assertEqual(len(calls), 2)
        engine.speed = 1.1
        engine.synthesize("测试")
        self.assertEqual(len(calls), 3)
        for index in range(40):
            engine.synthesize(f"测试{index}")
        self.assertEqual(len(engine._cache), 32)
        self.assertEqual(engine._cache_bytes, sum(len(value[0]) for value in engine._cache.values()))

    async def test_health_reports_actual_selected_model(self):
        self.app.state.engine.model_name = LEGACY_MODEL_NAME
        self.app.state.engine.speaker = 66
        self.app.state.engine.device = "cuda"
        result = (await self.client.get("/health")).json()
        self.assertEqual(result["model"], LEGACY_MODEL_NAME)
        self.assertEqual(result["speaker"], 66)
        self.assertEqual(result["device"], "cuda")


if __name__ == "__main__":
    unittest.main()
