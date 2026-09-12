from __future__ import annotations

import os
from pathlib import Path
import re
import threading

import numpy as np

MODEL_NAME = "vits-icefall-zh-aishell3"
DEFAULT_MODEL_DIR = Path(__file__).resolve().parents[1] / "models" / "tts" / MODEL_NAME


def normalize_text(text: str) -> str:
    # Change pronunciation only, never summarize or alter numeric values.
    text = re.sub(r"N\s*[·⋅*] ?m\b", "牛顿米", text, flags=re.IGNORECASE)
    text = re.sub(r"\bNm\b", "牛顿米", text)
    text = re.sub(r"(\d)\s*mm\b", r"\1毫米", text)
    text = re.sub(r"(\d)\s*kg\b", r"\1千克", text)
    return text.replace("℃", "摄氏度").replace("**", "").replace("`", "").strip()


class SpeechEngine:
    def __init__(self) -> None:
        self.loaded = False
        self.model_dir = Path(os.getenv("LOCAL_TTS_MODEL_DIR", str(DEFAULT_MODEL_DIR)))
        self.threads = min(4, max(1, int(os.getenv("LOCAL_TTS_THREADS", "2"))))
        self.speaker = int(os.getenv("LOCAL_TTS_SPEAKER", "66"))
        self._lock = threading.Lock()
        self._tts = None

    def load(self) -> None:
        import sherpa_onnx

        root = self.model_dir
        required = ["model.onnx", "tokens.txt", "lexicon.txt", "phone.fst", "date.fst", "number.fst"]
        if not all((root / name).is_file() for name in required):
            raise RuntimeError("TTS model missing. Run scripts/bootstrap_local_tts.sh.")
        config = sherpa_onnx.OfflineTtsConfig(
            model=sherpa_onnx.OfflineTtsModelConfig(
                vits=sherpa_onnx.OfflineTtsVitsModelConfig(
                    model=str(root / "model.onnx"),
                    tokens=str(root / "tokens.txt"),
                    lexicon=str(root / "lexicon.txt"),
                ),
                num_threads=self.threads,
                provider="cpu",
            ),
            rule_fsts=",".join(str(root / name) for name in ["phone.fst", "date.fst", "number.fst"]),
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
            audio = self._tts.generate(normalize_text(text), sid=self.speaker, speed=1.0)
            samples = np.asarray(audio.samples)
            if samples.size == 0 or not np.isfinite(samples).all():
                raise RuntimeError("Empty or invalid synthesized audio.")
            if samples.size > audio.sample_rate * 90:
                raise RuntimeError("Synthesized audio exceeds 90 seconds.")
            pcm = (np.clip(samples, -1.0, 1.0) * 32767).astype("<i2").tobytes()
            return pcm, audio.sample_rate
