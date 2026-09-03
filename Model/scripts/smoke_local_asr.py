#!/usr/bin/env python3
"""Stream a WAV file through the same local ASR WebSocket used by Godot."""

from __future__ import annotations

import argparse
import asyncio
import json
from pathlib import Path

import numpy as np
import soundfile as sf
import websockets


def pcm16_from_wav(path: Path) -> bytes:
    audio, sample_rate = sf.read(path, dtype="float32", always_2d=True)
    mono = audio.mean(axis=1)
    if sample_rate != 16_000:
        duration = len(mono) / sample_rate
        output_length = max(1, round(duration * 16_000))
        source_positions = np.linspace(0.0, 1.0, len(mono), endpoint=False)
        target_positions = np.linspace(0.0, 1.0, output_length, endpoint=False)
        mono = np.interp(target_positions, source_positions, mono)
    pcm = (np.clip(mono, -1.0, 1.0) * 32767.0).astype("<i2")
    return pcm.tobytes()


async def run(endpoint: str, wav_path: Path, *, auto_vad: bool = False) -> str:
    pcm = pcm16_from_wav(wav_path)
    packet_bytes = 16_000 * 2 * 100 // 1000
    final_text = ""
    async with websockets.connect(endpoint, open_timeout=10, max_size=262_144) as socket:
        await socket.send(
            json.dumps(
                {
                    "type": "start",
                    "sample_rate": 16_000,
                    "format": "pcm_s16le",
                    "need_vad": auto_vad,
                    "vad_silence_msec": 600,
                    "stable_partial_msec": 1800,
                    "hotwords": "智能助手 30",
                },
                ensure_ascii=False,
            )
        )
        ready = json.loads(await socket.recv())
        if ready.get("type") != "ready":
            raise RuntimeError(f"Local ASR did not become ready: {ready}")
        async def receive_results() -> None:
            nonlocal final_text
            async for raw in socket:
                message = json.loads(raw)
                if message.get("type") == "error":
                    raise RuntimeError(str(message.get("message", "Local ASR failed")))
                if message.get("type") == "transcript":
                    reason = str(message.get("endpoint_reason", ""))
                    reason_suffix = f" ({reason})" if reason else ""
                    print(
                        f"{'final' if message.get('is_final') else 'partial'}"
                        f"{reason_suffix}: {message.get('text', '')}"
                    )
                    if message.get("is_final"):
                        final_text = str(message.get("text", "")).strip()
                if message.get("type") == "finished":
                    return

        receiver = asyncio.create_task(receive_results())
        audio_to_send = pcm
        if auto_vad:
            audio_to_send += bytes(16_000 * 2 * 1200 // 1000)
        for offset in range(0, len(audio_to_send), packet_bytes):
            if receiver.done():
                break
            await socket.send(audio_to_send[offset : offset + packet_bytes])
        if not auto_vad:
            await socket.send(json.dumps({"type": "finish"}))
        await asyncio.wait_for(receiver, timeout=30.0)
    if not final_text:
        raise RuntimeError("Local ASR returned no final transcript")
    return final_text


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("wav", type=Path)
    parser.add_argument("--endpoint", default="ws://127.0.0.1:8765/ws/asr")
    parser.add_argument(
        "--auto-vad",
        action="store_true",
        help="Wait for streaming FSMN-VAD to end the utterance instead of sending finish.",
    )
    args = parser.parse_args()
    final_text = asyncio.run(run(args.endpoint, args.wav, auto_vad=args.auto_vad))
    print(f"Local ASR smoke test passed: {final_text}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
