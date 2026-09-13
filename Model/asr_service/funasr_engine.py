"""Thin, lazy-loaded wrapper around FunASR's streaming Paraformer model."""

from __future__ import annotations

from dataclasses import dataclass, field
import os
import threading
from typing import Any

import numpy as np


DEFAULT_MODEL = "paraformer-zh-streaming"
DEFAULT_VAD_MODEL = "fsmn-vad"
DEFAULT_DEVICE = "cuda"
DEFAULT_CHUNK_SIZE = (0, 10, 5)
STREAMING_FRAME_MSEC = 60
WARMUP_SAMPLE_COUNT = 16_000 * DEFAULT_CHUNK_SIZE[1] * STREAMING_FRAME_MSEC // 1000
VAD_CHUNK_MSEC = 100


@dataclass
class FunAsrSession:
    cache: dict[str, Any] = field(default_factory=dict)
    vad_cache: dict[str, Any] = field(default_factory=dict)
    text_parts: list[str] = field(default_factory=list)
    hotwords: str = ""


class FunAsrEngine:
    """Own one model and serialize inference across independent streams."""

    def __init__(self, model_name: str | None = None, device: str | None = None) -> None:
        self.model_name = model_name or os.getenv("FUNASR_MODEL", DEFAULT_MODEL)
        self.vad_model_name = os.getenv("FUNASR_VAD_MODEL", DEFAULT_VAD_MODEL)
        self.device = device or os.getenv("FUNASR_DEVICE", DEFAULT_DEVICE)
        self._model: Any | None = None
        self._vad_model: Any | None = None
        self._warmed_up = False
        self._load_error = ""
        self._lock = threading.Lock()

    @property
    def loaded(self) -> bool:
        return self._model is not None and self._vad_model is not None

    @property
    def vad_loaded(self) -> bool:
        return self._vad_model is not None

    @property
    def load_error(self) -> str:
        return self._load_error

    @property
    def warmed_up(self) -> bool:
        return self._warmed_up

    def load(self) -> None:
        if self._model is not None:
            return
        with self._lock:
            if self._model is not None:
                return
            try:
                from funasr import AutoModel

                model = AutoModel(
                    model=self.model_name,
                    device=self.device,
                    disable_update=True,
                )
                vad_model = AutoModel(
                    model=self.vad_model_name,
                    device=self.device,
                    disable_update=True,
                )
                if os.getenv("FUNASR_WARMUP", "1") != "0":
                    model.generate(
                        input=np.zeros(WARMUP_SAMPLE_COUNT, dtype=np.float32),
                        cache={},
                        is_final=True,
                        chunk_size=list(DEFAULT_CHUNK_SIZE),
                        encoder_chunk_look_back=4,
                        decoder_chunk_look_back=1,
                    )
                    self._warmed_up = True
                self._model = model
                self._vad_model = vad_model
                self._load_error = ""
            except Exception as exc:
                self._load_error = str(exc)
                raise

    def create_session(self, hotwords: str = "") -> FunAsrSession:
        self.load()
        return FunAsrSession(hotwords=hotwords.strip())

    def recognize(self, session: FunAsrSession, pcm16: bytes, *, is_final: bool) -> str:
        if not pcm16 and not is_final:
            return "".join(session.text_parts)
        self.load()
        audio = np.frombuffer(pcm16, dtype="<i2").astype(np.float32) / 32768.0
        kwargs: dict[str, Any] = {
            "input": audio,
            "cache": session.cache,
            "is_final": is_final,
            "chunk_size": list(DEFAULT_CHUNK_SIZE),
            "encoder_chunk_look_back": 4,
            "decoder_chunk_look_back": 1,
        }
        if session.hotwords:
            kwargs["hotword"] = session.hotwords
        with self._lock:
            result = self._model.generate(**kwargs)
        piece = ""
        if result and isinstance(result[0], dict):
            piece = str(result[0].get("text", "")).strip()
        if piece:
            session.text_parts.append(piece)
        return "".join(session.text_parts).strip()

    def detect_speech(
        self,
        session: FunAsrSession,
        pcm16: bytes,
        *,
        is_final: bool,
        max_end_silence_msec: int,
    ) -> tuple[bool, bool]:
        """Return whether streaming FSMN-VAD found a speech start or end."""
        self.load()
        audio = np.frombuffer(pcm16, dtype="<i2").astype(np.float32) / 32768.0
        duration_msec = max(
            10,
            len(pcm16) * 1000 // (16_000 * 2),
        )
        with self._lock:
            result = self._vad_model.generate(
                input=audio,
                cache=session.vad_cache,
                is_final=is_final,
                chunk_size=duration_msec if pcm16 else VAD_CHUNK_MSEC,
                max_end_silence_time=max_end_silence_msec,
            )

        speech_started = False
        speech_ended = False
        if result and isinstance(result[0], dict):
            for segment in result[0].get("value", []):
                if not isinstance(segment, (list, tuple)) or len(segment) < 2:
                    continue
                speech_started = speech_started or int(segment[0]) >= 0
                speech_ended = speech_ended or int(segment[1]) >= 0
        return speech_started, speech_ended
