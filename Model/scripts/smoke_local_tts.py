"""Real speech smoke; saves synthetic samples, not user conversations."""
from __future__ import annotations
import json
from pathlib import Path
import statistics
import time
import urllib.request
import wave

URL = "http://127.0.0.1:8767"
with urllib.request.urlopen(URL + "/health", timeout=3) as health_response:
    health = json.load(health_response)
assert health.get("service") == "local-tts" and health.get("status") == "ready"
samples = ["我在。", "工作清单已打开。", "你是否想打开工作清单？", "不要超过二十五牛顿米。", "当前在第十七页。"]
times = []
for index, text in enumerate(samples):
    started = time.perf_counter()
    request = urllib.request.Request(URL + "/v1/speech",
        data=json.dumps({"text": text}).encode(), headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(request, timeout=30) as response:
        pcm = response.read()
        rate = int(response.headers["X-Sample-Rate"])
        assert response.headers["X-Audio-Format"] == "pcm_s16le"
    elapsed = time.perf_counter() - started
    assert len(pcm) > rate // 5 and len(pcm) % 2 == 0 and any(pcm)
    times.append(elapsed)
    output = Path(__file__).resolve().parents[1] / "generated" / "tts_smoke"
    output.mkdir(parents=True, exist_ok=True)
    with wave.open(str(output / f"sample_{index}.wav"), "wb") as wav:
        wav.setnchannels(1)
        wav.setsampwidth(2)
        wav.setframerate(rate)
        wav.writeframes(pcm)
    print(json.dumps({"text": text, "generation_seconds": round(elapsed, 3),
                      "audio_seconds": round(len(pcm) / 2 / rate, 3)}, ensure_ascii=False))
print(f"PASS: {len(samples)} real {health.get('device')} syntheses ({health.get('model')}); "
      f"median={statistics.median(times):.3f}s (may include cached responses)")
