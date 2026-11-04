"""Synthetic compatibility smoke; no user recordings, no Godot tool execution."""
from __future__ import annotations

import json
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from agent_service.agent_factory import AgentFactory
from agent_service.config import Settings
from agent_service.connection_manager import ConnectionManager
from agent_service.health import _probe_model_server_sync
from agent_service.knowledge_harness import OpenAICompatibleJsonClient
from agent_service.model_endpoint import request_json


def check(settings: Settings) -> None:
    health = _probe_model_server_sync(settings)
    if not health.reachable or not health.model_found:
        raise RuntimeError("Model health check failed: " + health.error)
    factory = AgentFactory(settings, ConnectionManager())
    result = factory.run("compatibility-probe", "greeting", [{"role": "user", "content": "你好"}], allowed_tools=[])
    if result.route != "direct_answer" or not result.answer.strip() or result.tool_name != "respond_directly":
        raise RuntimeError("Native tool-selection/harness probe failed")
    schema = {"type": "object", "properties": {"ok": {"type": "boolean"}},
              "required": ["ok"], "additionalProperties": False}
    response = request_json(settings.model_server + "/chat/completions", settings.api_key,
        settings.model_request_timeout_seconds, {
            "model": settings.model_name, "messages": [{"role": "user", "content": "Call compatibility_check with ok=true."}],
            "tools": [{"type": "function", "function": {"name": "compatibility_check", "description": "Synthetic check, no action", "parameters": schema}}],
            "tool_choice": {"type": "function", "function": {"name": "compatibility_check"}},
            "stream": False, "max_tokens": 64,
        })
    calls = response.get("choices", [{}])[0].get("message", {}).get("tool_calls", [])
    if len(calls) != 1 or calls[0].get("function", {}).get("name") != "compatibility_check" or json.loads(calls[0]["function"]["arguments"]) != {"ok": True}:
        raise RuntimeError("Named tool_choice probe failed")
    selector = OpenAICompatibleJsonClient(settings.model_server, settings.model_name, api_key=settings.api_key,
        timeout_seconds=settings.model_request_timeout_seconds, json_mode=settings.model_json_mode)
    if json.loads(selector('Return exactly the JSON object {"ok":true}.', schema)) != {"ok": True}:
        raise RuntimeError("JSON output probe failed")


if __name__ == "__main__":
    try:
        check(Settings.from_env())
        print("External model compatibility PASS (synthetic only; no Godot actions)")
    except Exception as exc:
        # Upstream text and credentials must never enter launcher status/logs.
        print(f"External model compatibility FAILED ({type(exc).__name__}); verify model ID, authentication, tools and JSON mode")
        raise SystemExit(1)
