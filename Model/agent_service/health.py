from __future__ import annotations

import asyncio
from dataclasses import dataclass

from agent_service.config import Settings
from agent_service.model_endpoint import request_json


@dataclass(slots=True)
class ModelHealth:
    reachable: bool
    model_found: bool
    error: str = ""


async def probe_model_server(settings: Settings) -> ModelHealth:
    return await asyncio.to_thread(_probe_model_server_sync, settings)


def _probe_model_server_sync(settings: Settings) -> ModelHealth:
    try:
        if settings.model_health_check == "chat":
            payload = request_json(settings.model_server + "/chat/completions", settings.api_key,
                settings.vllm_health_timeout_seconds, {"model": settings.model_name,
                "messages": [{"role": "user", "content": "Reply OK."}], "max_tokens": 8, "stream": False})
            choices = payload.get("choices", [])
            valid = bool(choices and isinstance(choices[0], dict) and choices[0].get("message", {}).get("content"))
            return ModelHealth(reachable=True, model_found=valid, error="" if valid else "chat health probe returned no text")
        payload = request_json(settings.models_url, settings.api_key, settings.vllm_health_timeout_seconds)
    except (RuntimeError, ValueError, TypeError, IndexError, AttributeError) as exc:
        return ModelHealth(reachable=False, model_found=False, error=str(exc))

    models = payload.get("data", []) if isinstance(payload, dict) else []
    if not isinstance(models, list):
        return ModelHealth(reachable=True, model_found=False, error="models response must contain a data array")
    model_ids = {
        str(item.get("id", ""))
        for item in models
        if isinstance(item, dict) and item.get("id")
    }
    return ModelHealth(
        reachable=True,
        model_found=settings.model_name in model_ids,
        error="" if settings.model_name in model_ids else "configured model was not advertised",
    )
