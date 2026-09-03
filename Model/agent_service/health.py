from __future__ import annotations

import asyncio
import json
import urllib.error
import urllib.request
from dataclasses import dataclass
from typing import Any

from agent_service.config import Settings


@dataclass(slots=True)
class ModelHealth:
    reachable: bool
    model_found: bool
    error: str = ""


async def probe_model_server(settings: Settings) -> ModelHealth:
    return await asyncio.to_thread(_probe_model_server_sync, settings)


def _probe_model_server_sync(settings: Settings) -> ModelHealth:
    request = urllib.request.Request(settings.models_url, method="GET")
    if settings.api_key:
        request.add_header("Authorization", f"Bearer {settings.api_key}")
    try:
        with urllib.request.urlopen(
            request, timeout=settings.vllm_health_timeout_seconds
        ) as response:
            payload: Any = json.loads(response.read().decode("utf-8"))
    except (OSError, ValueError, urllib.error.URLError) as exc:
        return ModelHealth(reachable=False, model_found=False, error=str(exc))

    models = payload.get("data", []) if isinstance(payload, dict) else []
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
