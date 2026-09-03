"""PCM buffering, neural VAD, and utterance lifecycle for streaming ASR."""

from __future__ import annotations

from dataclasses import dataclass
import math
import struct
import time
from typing import Any, Callable, Protocol


SAMPLE_RATE = 16_000
BYTES_PER_SAMPLE = 2
MODEL_CHUNK_MSEC = 600
MODEL_CHUNK_BYTES = SAMPLE_RATE * BYTES_PER_SAMPLE * MODEL_CHUNK_MSEC // 1000
MAX_BUFFERED_BYTES = SAMPLE_RATE * BYTES_PER_SAMPLE * 30
PRE_ROLL_MSEC = 800
DEFAULT_STABLE_PARTIAL_MSEC = 1800
FINAL_FLUSH_PADDING_MSEC = 300
FINAL_FLUSH_PADDING_BYTES = (
    SAMPLE_RATE * BYTES_PER_SAMPLE * FINAL_FLUSH_PADDING_MSEC // 1000
)


def monotonic_msec() -> int:
    return time.monotonic_ns() // 1_000_000


class StreamingEngine(Protocol):
    def create_session(self, hotwords: str = "") -> Any: ...

    def recognize(self, session: Any, pcm16: bytes, *, is_final: bool) -> str: ...


@dataclass(frozen=True)
class TranscriptEvent:
    text: str
    is_final: bool
    endpoint_reason: str = ""


def pcm16_rms(pcm16: bytes) -> float:
    sample_count = len(pcm16) // 2
    if sample_count <= 0:
        return 0.0
    samples = struct.unpack(f"<{sample_count}h", pcm16[: sample_count * 2])
    mean_square = sum(sample * sample for sample in samples) / sample_count
    return math.sqrt(mean_square) / 32768.0


class StreamingAsrSession:
    def __init__(
        self,
        engine: StreamingEngine,
        *,
        need_vad: bool = True,
        vad_silence_msec: int = 600,
        max_speak_msec: int = 15_000,
        speech_threshold: float = 0.012,
        stable_partial_msec: int = DEFAULT_STABLE_PARTIAL_MSEC,
        hotwords: str = "",
        clock_msec: Callable[[], int] | None = None,
    ) -> None:
        self.engine = engine
        self.need_vad = need_vad
        self.vad_silence_msec = max(400, min(vad_silence_msec, 5000))
        self.max_speak_msec = max(1000, min(max_speak_msec, 90_000))
        self.speech_threshold = max(0.001, min(speech_threshold, 0.5))
        self.stable_partial_msec = max(1000, min(stable_partial_msec, 5000))
        self.hotwords = hotwords
        self._clock_msec = clock_msec or monotonic_msec
        self._engine_session = engine.create_session(hotwords)
        self._detect_speech = getattr(engine, "detect_speech", None)
        self._uses_neural_vad = need_vad and callable(self._detect_speech)
        self._model_buffer = bytearray()
        self._pre_roll = bytearray()
        self._speaking = not need_vad
        self._speech_msec = 0
        self._silence_msec = 0
        self._input_msec = 0
        self._last_text = ""
        self._last_text_change_msec = -1
        self._last_audio_wall_msec = -1
        self._last_text_change_wall_msec = -1
        self.finished = False

    def feed(self, pcm16: bytes) -> list[TranscriptEvent]:
        if self.finished or not pcm16:
            return []
        if len(pcm16) % 2:
            pcm16 = pcm16[:-1]
        if not pcm16:
            return []
        self._last_audio_wall_msec = self._clock_msec()
        chunk_msec = len(pcm16) * 1000 // (SAMPLE_RATE * BYTES_PER_SAMPLE)
        self._input_msec += chunk_msec
        speech_ended = False
        if self._uses_neural_vad:
            speech_started, speech_ended = self._detect_speech(
                self._engine_session,
                pcm16,
                is_final=False,
                max_end_silence_msec=self.vad_silence_msec,
            )
            if not self._speaking:
                self._append_pre_roll(pcm16)
                if not speech_started:
                    return []
                self._speaking = True
                pcm16 = bytes(self._pre_roll)
                self._pre_roll.clear()
                chunk_msec = len(pcm16) * 1000 // (SAMPLE_RATE * BYTES_PER_SAMPLE)
        else:
            is_speech = pcm16_rms(pcm16) >= self.speech_threshold
            if self.need_vad and not self._speaking:
                self._append_pre_roll(pcm16)
                if not is_speech:
                    return []
                self._speaking = True
                pcm16 = bytes(self._pre_roll)
                self._pre_roll.clear()
                chunk_msec = len(pcm16) * 1000 // (SAMPLE_RATE * BYTES_PER_SAMPLE)
            if is_speech:
                self._silence_msec = 0
            else:
                self._silence_msec += chunk_msec
        self._speech_msec += chunk_msec
        self._model_buffer.extend(pcm16)
        if len(self._model_buffer) > MAX_BUFFERED_BYTES:
            raise ValueError("ASR session buffered more than 30 seconds of audio")

        events = self._drain_model_chunks()
        endpoint_reason = ""
        if self.need_vad:
            if speech_ended:
                endpoint_reason = "neural_vad"
            elif not self._uses_neural_vad and self._silence_msec >= self.vad_silence_msec:
                endpoint_reason = "energy_vad"
            elif self._stable_partial_timed_out():
                endpoint_reason = "stable_partial_timeout"
            elif self._speech_msec >= self.max_speak_msec:
                endpoint_reason = "max_speak_timeout"
        if endpoint_reason:
            final = self.finish(endpoint_reason)
            if final is not None:
                events.append(final)
        return events

    def poll_timeout(self) -> TranscriptEvent | None:
        """Finalize a stalled utterance even when no more audio packets arrive."""
        if self.finished or not self._speaking:
            return None
        now_msec = self._clock_msec()
        if (
            self._last_text_change_wall_msec >= 0
            and now_msec - self._last_text_change_wall_msec
            >= self.stable_partial_msec
        ):
            return self.finish("stable_partial_wall_timeout")
        if (
            self._last_audio_wall_msec >= 0
            and now_msec - self._last_audio_wall_msec >= self.stable_partial_msec
        ):
            return self.finish("input_idle_timeout")
        return None

    def finish(self, endpoint_reason: str = "explicit_finish") -> TranscriptEvent | None:
        if self.finished:
            return None
        self.finished = True
        if not self._speaking:
            return None
        remaining = bytes(self._model_buffer)
        self._model_buffer.clear()
        if len(remaining) < FINAL_FLUSH_PADDING_BYTES:
            remaining += bytes(FINAL_FLUSH_PADDING_BYTES - len(remaining))
        text = self.engine.recognize(self._engine_session, remaining, is_final=True)
        self._last_text = text or self._last_text
        if not self._last_text:
            return None
        return TranscriptEvent(self._last_text, True, endpoint_reason)

    def _drain_model_chunks(self) -> list[TranscriptEvent]:
        events: list[TranscriptEvent] = []
        while len(self._model_buffer) >= MODEL_CHUNK_BYTES:
            chunk = bytes(self._model_buffer[:MODEL_CHUNK_BYTES])
            del self._model_buffer[:MODEL_CHUNK_BYTES]
            text = self.engine.recognize(self._engine_session, chunk, is_final=False)
            if text and text != self._last_text:
                self._last_text = text
                self._last_text_change_msec = self._input_msec
                self._last_text_change_wall_msec = self._clock_msec()
                events.append(TranscriptEvent(text, False))
        return events

    def _append_pre_roll(self, pcm16: bytes) -> None:
        self._pre_roll.extend(pcm16)
        pre_roll_bytes = SAMPLE_RATE * BYTES_PER_SAMPLE * PRE_ROLL_MSEC // 1000
        if len(self._pre_roll) > pre_roll_bytes:
            del self._pre_roll[:-pre_roll_bytes]

    def _stable_partial_timed_out(self) -> bool:
        return (
            self._last_text_change_msec >= 0
            and self._input_msec - self._last_text_change_msec
            >= self.stable_partial_msec
        )
