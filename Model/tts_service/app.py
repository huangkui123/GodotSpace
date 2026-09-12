from __future__ import annotations

import asyncio
from contextlib import asynccontextmanager
import json
import logging
import os
from typing import Any

from fastapi import FastAPI, HTTPException, Request, Response

from .engine import MODEL_NAME, SpeechEngine

LOGGER = logging.getLogger("tts_service")
MAX_BODY_BYTES = 4096
MAX_TEXT_CHARS = 500


def create_app(engine: Any | None = None) -> FastAPI:
    speech = engine if engine is not None else SpeechEngine()

    @asynccontextmanager
    async def lifespan(app: FastAPI):
        await asyncio.to_thread(speech.load)
        yield
        task = app.state.active_task
        if task is not None:
            await asyncio.gather(asyncio.shield(task), return_exceptions=True)

    app = FastAPI(title="GodotSpace Local CPU TTS", lifespan=lifespan)
    app.state.engine = speech
    app.state.busy = False
    app.state.active_task = None

    @app.get("/health")
    async def health() -> dict[str, Any]:
        return {"status": "ready" if speech.loaded else "not_loaded",
                "service": "local-tts", "model": MODEL_NAME, "device": "cpu",
                "busy": app.state.busy, "pid": os.getpid(),
                "instance": os.getenv("LOCAL_TTS_INSTANCE", "")}

    async def generate(text: str) -> tuple[bytes, int]:
        try:
            return await asyncio.to_thread(speech.synthesize, text)
        except Exception:
            LOGGER.warning("Speech synthesis failed", exc_info=False)
            raise
        finally:
            app.state.busy = False

    @app.post("/v1/speech")
    async def synthesize(request: Request) -> Response:
        # No CORS and no browser-origin requests on this loopback-only service.
        if request.headers.get("origin"):
            raise HTTPException(403, "Browser-origin synthesis is disabled")
        body = bytearray()
        async for chunk in request.stream():
            body.extend(chunk)
            if len(body) > MAX_BODY_BYTES:
                raise HTTPException(413, "Request too large")
        try:
            data = json.loads(body)
        except (ValueError, UnicodeDecodeError):
            raise HTTPException(400, "Invalid JSON") from None
        if not isinstance(data, dict) or set(data) != {"text"}:
            raise HTTPException(422, "Only text is accepted")
        text = data["text"]
        if not isinstance(text, str) or not text.strip() or len(text) > MAX_TEXT_CHARS:
            raise HTTPException(422, "Text must contain 1-500 characters")
        if not speech.loaded:
            raise HTTPException(503, "TTS not ready")
        if app.state.busy:
            raise HTTPException(429, "TTS busy; retry later")
        app.state.busy = True
        task = asyncio.create_task(generate(text))
        app.state.active_task = task
        # A cancelled HTTP request must not release the inference slot while
        # its non-cancellable native CPU worker is still running.
        task.add_done_callback(lambda done: done.exception() if not done.cancelled() else None)
        try:
            pcm, sample_rate = await asyncio.wait_for(asyncio.shield(task), timeout=25)
        except asyncio.TimeoutError:
            raise HTTPException(504, "Synthesis timed out") from None
        except Exception:
            raise HTTPException(503, "Synthesis failed") from None
        return Response(pcm, media_type="application/octet-stream", headers={
            "X-Audio-Format": "pcm_s16le", "X-Sample-Rate": str(sample_rate),
            "Cache-Control": "no-store",
        })

    return app


app = create_app()
