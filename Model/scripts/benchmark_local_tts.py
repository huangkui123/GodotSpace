"""Offline TTS timing and synthetic voice audition; no user audio or cloud calls."""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import statistics
import sys
import time
import wave

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from tts_service.engine import SpeechEngine, DEFAULT_KOKORO_SPEAKER  # noqa: E402

SAMPLES = ["我在。", "工作清单已打开。", "你是否想打开工作清单？",
           "当前在第十七页。力矩为 2.5 N·m，请勿超过这个值。"]


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--model", choices=("kokoro", "vits"), default="kokoro")
    parser.add_argument("--speakers", type=int, nargs="+", default=[DEFAULT_KOKORO_SPEAKER])
    parser.add_argument("--threads", type=int, choices=(1, 2, 3, 4), default=2)
    parser.add_argument("--device", choices=("cpu", "cuda"), default="cpu")
    args = parser.parse_args()
    os.environ.update(LOCAL_TTS_MODEL=args.model, LOCAL_TTS_THREADS=str(args.threads),
                      LOCAL_TTS_SPEAKER=str(args.speakers[0]), LOCAL_TTS_DEVICE=args.device)
    output = ROOT / "generated/tts_audition" / f"{args.model}-{args.device}-{args.threads}threads"
    output.mkdir(parents=True, exist_ok=True)
    engine = SpeechEngine()
    started = time.perf_counter()
    engine.load()
    print(json.dumps({"model": engine.model_name, "load_seconds": round(time.perf_counter() - started, 3)}), flush=True)
    records = []
    for speaker in args.speakers:
        if not 0 <= speaker < engine._tts.num_speakers:
            raise ValueError("Speaker out of range")
        engine.speaker = speaker
        for index, text in enumerate(SAMPLES):
            engine._cache.clear()
            engine._cache_bytes = 0
            started = time.perf_counter()
            pcm, rate = engine.synthesize(text)
            elapsed = time.perf_counter() - started
            duration = len(pcm) / 2 / rate
            cached_started = time.perf_counter()
            assert engine.synthesize(text) == (pcm, rate)
            cached_ms = (time.perf_counter() - cached_started) * 1000
            path = output / f"voice_{speaker}_{index}.wav"
            with wave.open(str(path), "wb") as wav:
                wav.setnchannels(1)
                wav.setsampwidth(2)
                wav.setframerate(rate)
                wav.writeframes(pcm)
            record = {"speaker": speaker, "text": text, "generation_seconds": round(elapsed, 3),
                      "audio_seconds": round(duration, 3), "rtf": round(elapsed / duration, 3),
                      "sample_rate": rate, "cached_ms": round(cached_ms, 3), "file": path.name}
            records.append(record)
            print(json.dumps(record, ensure_ascii=False), flush=True)
    (output / "results.json").write_text(json.dumps(records, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"Median generation: {statistics.median(r['generation_seconds'] for r in records):.3f}s", flush=True)


if __name__ == "__main__":
    main()
