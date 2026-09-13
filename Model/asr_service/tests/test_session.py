from __future__ import annotations

import struct
import unittest

from asr_service.session import (
    DEFAULT_STABLE_PARTIAL_MSEC,
    FINAL_FLUSH_PADDING_BYTES,
    MODEL_CHUNK_MSEC,
    StreamingAsrSession,
)


def pcm(value: int, milliseconds: int = 200) -> bytes:
    samples = 16_000 * milliseconds // 1000
    return struct.pack(f"<{samples}h", *([value] * samples))


class FakeEngine:
    loaded = True
    model_name = "fake-streaming"
    device = "test"
    load_error = ""

    def create_session(self, hotwords: str = "") -> dict[str, object]:
        return {"calls": 0, "hotwords": hotwords}

    def recognize(self, session: dict[str, object], audio: bytes, *, is_final: bool) -> str:
        session["calls"] = int(session["calls"]) + 1
        if is_final:
            session["final_audio_bytes"] = len(audio)
            session["final_audio"] = audio
        if not audio and not is_final:
            return ""
        return "智能助手" if not is_final else "智能助手打开工作清单"


class FakeNeuralVadEngine(FakeEngine):
    def __init__(self, speech_end_call: int | None) -> None:
        self.speech_end_call = speech_end_call

    def create_session(self, hotwords: str = "") -> dict[str, object]:
        return {"calls": 0, "vad_calls": 0, "hotwords": hotwords}

    def detect_speech(
        self,
        session: dict[str, object],
        pcm16: bytes,
        *,
        is_final: bool,
        max_end_silence_msec: int,
    ) -> tuple[bool, bool]:
        del pcm16, is_final, max_end_silence_msec
        session["vad_calls"] = int(session["vad_calls"]) + 1
        call = int(session["vad_calls"])
        return call == 1, self.speech_end_call == call


class StreamingAsrSessionTests(unittest.TestCase):
    def test_default_silence_window_is_latency_tuned(self) -> None:
        session = StreamingAsrSession(FakeEngine())
        self.assertEqual(session.vad_silence_msec, 600)
        self.assertEqual(session.stable_partial_msec, DEFAULT_STABLE_PARTIAL_MSEC)
        self.assertEqual(MODEL_CHUNK_MSEC, 600)

    def test_streams_partial_and_final_after_silence(self) -> None:
        session = StreamingAsrSession(
            FakeEngine(), vad_silence_msec=600, speech_threshold=0.01
        )
        events = []
        for _ in range(3):
            events.extend(session.feed(pcm(4000)))
        self.assertTrue(any(not event.is_final for event in events))
        for _ in range(3):
            events.extend(session.feed(pcm(0)))
        self.assertTrue(session.finished)
        self.assertEqual(events[-1].text, "智能助手打开工作清单")
        self.assertTrue(events[-1].is_final)

    def test_silence_does_not_start_an_utterance(self) -> None:
        session = StreamingAsrSession(FakeEngine(), vad_silence_msec=600)
        events = []
        for _ in range(8):
            events.extend(session.feed(pcm(0)))
        self.assertEqual(events, [])
        self.assertFalse(session.finished)

    def test_dictation_finishes_only_on_explicit_finish(self) -> None:
        session = StreamingAsrSession(FakeEngine(), need_vad=False)
        for _ in range(4):
            session.feed(pcm(4000))
        self.assertFalse(session.finished)
        final = session.finish()
        self.assertIsNotNone(final)
        self.assertTrue(final.is_final)

    def test_neural_vad_ends_noisy_audio_without_energy_threshold(self) -> None:
        session = StreamingAsrSession(
            FakeNeuralVadEngine(speech_end_call=10),
            vad_silence_msec=700,
            speech_threshold=0.5,
        )
        events = []
        for _ in range(10):
            events.extend(session.feed(pcm(4000, 100)))
        self.assertTrue(session.finished)
        self.assertTrue(events[-1].is_final)
        self.assertEqual(events[-1].endpoint_reason, "neural_vad")

    def test_unchanged_partial_does_not_cut_continuing_or_quiet_speech(self) -> None:
        for amplitude in (4000, 10):
            with self.subTest(amplitude=amplitude):
                now = [1000]
                session = StreamingAsrSession(
                    FakeNeuralVadEngine(speech_end_call=None),
                    clock_msec=lambda: now[0],
                )
                for _ in range(60):
                    now[0] += 100
                    session.feed(pcm(amplitude, 100))
                    self.assertIsNone(session.poll_timeout())
                    self.assertFalse(session.finished)

    def test_silence_watchdog_flushes_when_vad_never_ends(self) -> None:
        session = StreamingAsrSession(
            FakeNeuralVadEngine(speech_end_call=None),
            stable_partial_msec=1800,
        )
        events = []
        events.extend(session.feed(pcm(4000, 600)))
        for _ in range(18):
            events.extend(session.feed(pcm(0, 100)))
        self.assertTrue(session.finished)
        self.assertEqual(events[-1].text, "智能助手打开工作清单")
        self.assertEqual(events[-1].endpoint_reason, "silence_watchdog")

    def test_wall_clock_timeout_flushes_when_audio_packets_stop(self) -> None:
        now = [1_000]
        session = StreamingAsrSession(
            FakeNeuralVadEngine(speech_end_call=None),
            stable_partial_msec=1800,
            clock_msec=lambda: now[0],
        )
        events = session.feed(pcm(4000, 600))
        self.assertTrue(any(not event.is_final for event in events))

        now[0] += 1801
        final = session.poll_timeout()

        self.assertIsNotNone(final)
        self.assertTrue(session.finished)
        self.assertEqual(final.endpoint_reason, "input_idle_timeout")

    def test_idle_audio_timeout_finishes_before_any_partial(self) -> None:
        now = [2_000]
        session = StreamingAsrSession(
            FakeNeuralVadEngine(speech_end_call=None),
            stable_partial_msec=1800,
            clock_msec=lambda: now[0],
        )
        self.assertEqual(session.feed(pcm(4000, 100)), [])

        now[0] += 1801
        final = session.poll_timeout()

        self.assertIsNotNone(final)
        self.assertEqual(final.endpoint_reason, "input_idle_timeout")

    def test_final_flush_always_contains_lookahead_audio(self) -> None:
        session = StreamingAsrSession(FakeEngine(), need_vad=False)
        session.feed(pcm(4000, MODEL_CHUNK_MSEC))

        self.assertIsNotNone(session.finish())
        self.assertGreaterEqual(
            int(session._engine_session.get("final_audio_bytes", 0)),
            FINAL_FLUSH_PADDING_BYTES,
        )

    def test_odd_pcm_byte_is_ignored(self) -> None:
        session = StreamingAsrSession(FakeEngine(), need_vad=False)
        session.feed(pcm(4000) + b"\x00")
        self.assertIsNotNone(session.finish())

    def test_finish_preserves_tail_and_appends_full_lookahead_at_every_boundary(self) -> None:
        for tail_msec in (0, 100, 299, 300, 500, 599):
            with self.subTest(tail_msec=tail_msec):
                session = StreamingAsrSession(FakeEngine(), need_vad=False)
                session.feed(pcm(4000, MODEL_CHUNK_MSEC))
                tail = pcm(200, tail_msec)
                session.feed(tail)
                session.finish()
                self.assertEqual(session._engine_session["final_audio"], tail + bytes(FINAL_FLUSH_PADDING_BYTES))
                self.assertIsNone(session.finish())

    def test_max_speak_still_bounds_continuous_speech(self) -> None:
        session = StreamingAsrSession(FakeNeuralVadEngine(None), max_speak_msec=3000)
        events = []
        for _ in range(30):
            events.extend(session.feed(pcm(4000, 100)))
        self.assertEqual(events[-1].endpoint_reason, "max_speak_timeout")


if __name__ == "__main__":
    unittest.main()
