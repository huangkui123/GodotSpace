from __future__ import annotations

import unittest

from asr_service.funasr_engine import (
    DEFAULT_CHUNK_SIZE,
    DEFAULT_VAD_MODEL,
    FunAsrEngine,
    FunAsrSession,
    VAD_CHUNK_MSEC,
    WARMUP_SAMPLE_COUNT,
)


class FakeVadModel:
    def __init__(self) -> None:
        self.kwargs: dict[str, object] = {}

    def generate(self, **kwargs: object) -> list[dict[str, object]]:
        self.kwargs = kwargs
        return [{"value": [[120, 720]]}]


class FunAsrEngineConfigurationTests(unittest.TestCase):
    def test_uses_stable_streaming_chunk(self) -> None:
        self.assertEqual(DEFAULT_CHUNK_SIZE, (0, 10, 5))
        self.assertEqual(WARMUP_SAMPLE_COUNT, 16_000 * 600 // 1000)
        self.assertEqual(DEFAULT_VAD_MODEL, "fsmn-vad")
        self.assertEqual(VAD_CHUNK_MSEC, 100)

    def test_parses_streaming_fsmn_vad_endpoints(self) -> None:
        engine = FunAsrEngine(device="test")
        fake_vad = FakeVadModel()
        engine._model = object()
        engine._vad_model = fake_vad
        session = FunAsrSession()
        started, ended = engine.detect_speech(
            session,
            bytes(3200),
            is_final=False,
            max_end_silence_msec=700,
        )
        self.assertTrue(started)
        self.assertTrue(ended)
        self.assertIs(fake_vad.kwargs["cache"], session.vad_cache)
        self.assertEqual(fake_vad.kwargs["chunk_size"], 100)
        self.assertEqual(fake_vad.kwargs["max_end_silence_time"], 700)


if __name__ == "__main__":
    unittest.main()
