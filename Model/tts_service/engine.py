from __future__ import annotations

import os
import math
from pathlib import Path
import re
import threading
from collections import OrderedDict

import numpy as np

MODEL_NAME = "kokoro-int8-multi-lang-v1_1"
CUDA_MODEL_NAME = "kokoro-multi-lang-v1_1"
DEFAULT_KOKORO_SPEAKER = 17
LEGACY_MODEL_NAME = "vits-icefall-zh-aishell3"
DEFAULT_MODEL_DIR = Path(__file__).resolve().parents[1] / "models" / "tts" / MODEL_NAME


def normalize_text(text: str) -> str:
    # Change pronunciation only, never summarize or alter numeric values.
    text = re.sub(r"N\s*[·⋅*] ?m\b", "牛顿米", text, flags=re.IGNORECASE)
    text = re.sub(r"\bNm\b", "牛顿米", text)
    text = re.sub(r"(\d)\s*mm\b", r"\1毫米", text)
    text = re.sub(r"(\d)\s*kg\b", r"\1千克", text)
    text = re.sub(r"(?m)^\s{0,3}#{1,6}\s+", "", text)
    # A spaced sign before a number may be a negative/positive value, not a bullet.
    text = re.sub(r"(?m)^[ \t]*[-*+][ \t]+(?=[^\d\s])", "", text)
    return text.replace("℃", "摄氏度").replace("**", "").replace("`", "").strip()


class SpeechEngine:
    def __init__(self) -> None:
        self.loaded = False
        self.device = os.getenv("LOCAL_TTS_DEVICE", "cpu")
        if self.device not in ("cpu", "cuda"):
            raise ValueError("LOCAL_TTS_DEVICE must be cpu or cuda")
        override = os.getenv("LOCAL_TTS_MODEL_DIR", "")
        # Preserve old launchers that supplied the legacy directory explicitly.
        default_kind = "vits" if override and Path(override).name == LEGACY_MODEL_NAME else "kokoro"
        self.kind = os.getenv("LOCAL_TTS_MODEL", default_kind)
        if self.kind not in ("kokoro", "vits"):
            raise ValueError("LOCAL_TTS_MODEL must be kokoro or vits")
        if self.kind == "vits" and self.device != "cpu":
            raise ValueError("Legacy VITS supports CPU only")
        self.model_name = MODEL_NAME if self.kind == "kokoro" else LEGACY_MODEL_NAME
        if self.device == "cuda":
            self.model_name = CUDA_MODEL_NAME
        self.model_file = "model.int8.onnx" if self.kind == "kokoro" and self.device == "cpu" else "model.onnx"
        self.model_dir = Path(override) if override else DEFAULT_MODEL_DIR.parent / self.model_name
        self.threads = min(4, max(1, int(os.getenv("LOCAL_TTS_THREADS", "2"))))
        self.speaker = int(os.getenv("LOCAL_TTS_SPEAKER", str(DEFAULT_KOKORO_SPEAKER) if self.kind == "kokoro" else "66"))
        self.speed = float(os.getenv("LOCAL_TTS_SPEED", "1.0"))
        if not math.isfinite(self.speed) or not 0.7 <= self.speed <= 1.3:
            raise ValueError("LOCAL_TTS_SPEED must be between 0.7 and 1.3")
        self._lock = threading.Lock()
        self._tts = None
        self._cache: OrderedDict[tuple[int, float, str], tuple[bytes, int]] = OrderedDict()
        self._cache_bytes = 0

    def load(self) -> None:
        if self.device == "cuda":
            from .cuda_runtime import prepare_cuda
            prepare_cuda()
        import sherpa_onnx

        root = self.model_dir
        if self.kind == "kokoro":
            required = [self.model_file, "tokens.txt", "voices.bin", "lexicon-zh.txt", "lexicon-us-en.txt",
                        "phone-zh.fst", "date-zh.fst", "number-zh.fst"]
        else:
            required = ["model.onnx", "tokens.txt", "lexicon.txt", "phone.fst", "date.fst", "number.fst"]
        if not all((root / name).is_file() for name in required):
            raise RuntimeError("TTS model missing. Run scripts/bootstrap_local_tts.sh.")
        if self.kind == "kokoro":
            if not (root / "espeak-ng-data").is_dir():
                raise RuntimeError("Kokoro pronunciation data missing")
            model = sherpa_onnx.OfflineTtsModelConfig(
                kokoro=sherpa_onnx.OfflineTtsKokoroModelConfig(
                    model=str(root / self.model_file),
                    voices=str(root / "voices.bin"), tokens=str(root / "tokens.txt"),
                    data_dir=str(root / "espeak-ng-data"),
                    lexicon=",".join(str(root / name) for name in ["lexicon-us-en.txt", "lexicon-zh.txt"]),
                ), num_threads=self.threads, provider=self.device,
            )
            rules = ",".join(str(root / name) for name in ["phone-zh.fst", "date-zh.fst", "number-zh.fst"])
        else:
            model = sherpa_onnx.OfflineTtsModelConfig(
                vits=sherpa_onnx.OfflineTtsVitsModelConfig(
                    model=str(root / "model.onnx"),
                    tokens=str(root / "tokens.txt"),
                    lexicon=str(root / "lexicon.txt"),
                ),
                num_threads=self.threads,
                provider="cpu",
            )
            rules = ",".join(str(root / name) for name in ["phone.fst", "date.fst", "number.fst"])
        config = sherpa_onnx.OfflineTtsConfig(
            model=model,
            rule_fsts=rules,
            max_num_sentences=1,
        )
        if not config.validate():
            raise RuntimeError("Invalid offline TTS configuration.")
        self._tts = sherpa_onnx.OfflineTts(config)
        if not 0 <= self.speaker < self._tts.num_speakers:
            raise RuntimeError("LOCAL_TTS_SPEAKER is out of range.")
        self.synthesize("我在。")
        self.loaded = True

    def synthesize(self, text: str) -> tuple[bytes, int]:
        with self._lock:
            key = (self.speaker, self.speed, normalize_text(text))
            if key in self._cache:
                self._cache.move_to_end(key)
                return self._cache[key]
            audio = self._tts.generate(key[2], sid=self.speaker, speed=self.speed)
            samples = np.asarray(audio.samples)
            if samples.size == 0 or not np.isfinite(samples).all():
                raise RuntimeError("Empty or invalid synthesized audio.")
            if samples.size > audio.sample_rate * 90:
                raise RuntimeError("Synthesized audio exceeds 90 seconds.")
            pcm = (np.clip(samples, -1.0, 1.0) * 32767).astype("<i2").tobytes()
            # RAM only; never persist conversation text/audio. Bound both count and bytes.
            if len(pcm) <= 8 * 1024 * 1024:
                while self._cache and (len(self._cache) >= 32 or self._cache_bytes + len(pcm) > 8 * 1024 * 1024):
                    _, old = self._cache.popitem(last=False)
                    self._cache_bytes -= len(old[0])
                self._cache[key] = (pcm, audio.sample_rate)
                self._cache_bytes += len(pcm)
            return pcm, audio.sample_rate
