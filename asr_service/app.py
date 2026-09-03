"""FastAPI WebSocket service exposing local FunASR streaming recognition."""

from __future__ import annotations

import asyncio
from contextlib import asynccontextmanager
import json
import logging
import os
from typing import Any

from fastapi import FastAPI, WebSocket, WebSocketDisconnect

from . import __version__
from .funasr_engine import FunAsrEngine
from .session import StreamingAsrSession, TranscriptEvent


MAX_PACKET_BYTES = 64 * 1024
WATCHDOG_POLL_SECONDS = 0.2
LOGGER = logging.getLogger("asr_service")


def create_app(engine: Any | None = None) -> FastAPI:
    asr_engine = engine or FunAsrEngine()

    @asynccontextmanager
    async def lifespan(_: FastAPI):
        load = getattr(asr_engine, "load", None)
        if callable(load) and os.getenv("FUNASR_PRELOAD", "1") != "0":
            await asyncio.to_thread(load)
        yield

    app = FastAPI(
        title="GodotSpace Local FunASR",
        version=__version__,
        lifespan=lifespan,
    )
    app.state.engine = asr_engine

    @app.get("/health")
    async def health() -> dict[str, Any]:
        asr_engine = app.state.engine
        return {
            "status": "ready" if getattr(asr_engine, "loaded", False) else "not_loaded",
            "service": "local-funasr",
            "version": __version__,
            "model": getattr(asr_engine, "model_name", "test"),
            "vad_model": getattr(asr_engine, "vad_model_name", "test"),
            "vad_loaded": bool(getattr(asr_engine, "vad_loaded", False)),
            "device": getattr(asr_engine, "device", "test"),
            "warmed_up": bool(getattr(asr_engine, "warmed_up", False)),
            "load_error": getattr(asr_engine, "load_error", ""),
        }

    @app.websocket("/ws/asr")
    async def stream_asr(websocket: WebSocket) -> None:
        await websocket.accept()
        session: StreamingAsrSession | None = None
        try:
            first = await websocket.receive_text()
            request = json.loads(first)
            if not isinstance(request, dict) or request.get("type") != "start":
                await _send_error(websocket, "first message must be a start object")
                await websocket.close(code=1008)
                return
            if int(request.get("sample_rate", 0)) != 16_000:
                await _send_error(websocket, "sample_rate must be 16000")
                await websocket.close(code=1008)
                return
            if request.get("format") != "pcm_s16le":
                await _send_error(websocket, "format must be pcm_s16le")
                await websocket.close(code=1008)
                return
            try:
                session = await asyncio.to_thread(
                    StreamingAsrSession,
                    app.state.engine,
                    need_vad=bool(request.get("need_vad", True)),
                    vad_silence_msec=int(request.get("vad_silence_msec", 600)),
                    max_speak_msec=int(request.get("max_speak_msec", 15_000)),
                    stable_partial_msec=int(
                        request.get("stable_partial_msec", 1800)
                    ),
                    speech_threshold=float(
                        request.get(
                            "speech_threshold",
                            os.getenv("FUNASR_SPEECH_THRESHOLD", "0.012"),
                        )
                    ),
                    hotwords=str(request.get("hotwords", "")),
                )
            except Exception as exc:
                await _send_error(websocket, f"unable to load FunASR: {exc}")
                await websocket.close(code=1011)
                return
            await websocket.send_json({"type": "ready", "model": getattr(app.state.engine, "model_name", "test")})

            while True:
                try:
                    message = await asyncio.wait_for(
                        websocket.receive(), timeout=WATCHDOG_POLL_SECONDS
                    )
                except TimeoutError:
                    event = await asyncio.to_thread(session.poll_timeout)
                    if event is None:
                        continue
                    LOGGER.info(
                        "Local ASR watchdog finalized utterance (%s)",
                        event.endpoint_reason,
                    )
                    await _send_transcript(websocket, event)
                    await websocket.send_json({"type": "finished"})
                    await _let_client_close(websocket)
                    return
                if message.get("type") == "websocket.disconnect":
                    return
                pcm = message.get("bytes")
                if pcm is not None:
                    if len(pcm) > MAX_PACKET_BYTES:
                        await _send_error(websocket, "audio packet exceeds 65536 bytes")
                        await websocket.close(code=1009)
                        return
                    events = await asyncio.to_thread(session.feed, pcm)
                    for event in events:
                        await _send_transcript(websocket, event)
                    if session.finished:
                        await websocket.send_json({"type": "finished"})
                        await _let_client_close(websocket)
                        return
                    continue
                text = message.get("text")
                if text is None:
                    continue
                command = json.loads(text)
                if not isinstance(command, dict):
                    continue
                if command.get("type") == "finish":
                    LOGGER.info("Local ASR finish received")
                    event = await asyncio.to_thread(session.finish)
                    LOGGER.info(
                        "Local ASR final inference completed (has_transcript=%s)",
                        event is not None,
                    )
                    if event is not None:
                        LOGGER.info("Local ASR sending final transcript")
                        await _send_transcript(websocket, event)
                        LOGGER.info("Local ASR final transcript sent")
                    LOGGER.info("Local ASR sending finished event")
                    await websocket.send_json({"type": "finished"})
                    LOGGER.info("Local ASR finished event sent; waiting for client close")
                    await _let_client_close(websocket)
                    LOGGER.info("Local ASR WebSocket finished")
                    return
                if command.get("type") == "cancel":
                    LOGGER.info("Local ASR cancel received")
                    await websocket.close(code=1000)
                    return
        except (WebSocketDisconnect, json.JSONDecodeError):
            return
        except Exception as exc:
            LOGGER.exception("Local ASR WebSocket failed: %s", exc)
            try:
                await _send_error(websocket, str(exc))
                await websocket.close(code=1011)
            except RuntimeError:
                pass

    return app


async def _send_transcript(websocket: WebSocket, event: TranscriptEvent) -> None:
    payload = {"type": "transcript", "text": event.text, "is_final": event.is_final}
    if event.endpoint_reason:
        payload["endpoint_reason"] = event.endpoint_reason
    await websocket.send_json(payload)


async def _send_error(websocket: WebSocket, message: str) -> None:
    await websocket.send_json({"type": "error", "code": "local_asr_error", "message": message})


async def _let_client_close(websocket: WebSocket) -> None:
    """Keep final frames readable by Godot before completing the ASGI route.

    Godot's WebSocketPeer can observe STATE_CLOSED without exposing text frames
    queued immediately before a server close frame.  Let the client close after
    it consumes the explicit ``finished`` event, with a bounded server fallback.
    """
    try:
        message = await asyncio.wait_for(websocket.receive(), timeout=2.0)
        if message.get("type") == "websocket.disconnect":
            return
    except (TimeoutError, WebSocketDisconnect):
        pass
    try:
        await websocket.close(code=1000)
    except RuntimeError:
        pass


app = create_app()
