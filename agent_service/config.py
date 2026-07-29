from __future__ import annotations

import os
from dataclasses import dataclass


def _env_int(name: str, default: int, *, minimum: int = 1) -> int:
    raw = os.getenv(name, str(default)).strip()
    try:
        value = int(raw)
    except ValueError as exc:
        raise ValueError(f"{name} must be an integer, got {raw!r}") from exc
    if value < minimum:
        raise ValueError(f"{name} must be >= {minimum}, got {value}")
    return value


def _env_float(name: str, default: float, *, minimum: float = 0.0) -> float:
    raw = os.getenv(name, str(default)).strip()
    try:
        value = float(raw)
    except ValueError as exc:
        raise ValueError(f"{name} must be a number, got {raw!r}") from exc
    if value < minimum:
        raise ValueError(f"{name} must be >= {minimum}, got {value}")
    return value


@dataclass(frozen=True, slots=True)
class Settings:
    host: str = "127.0.0.1"
    port: int = 7861
    model_name: str = "Qwen/Qwen3-VL-2B-Instruct"
    model_server: str = "http://127.0.0.1:8000/v1"
    api_key: str = "EMPTY"
    tool_timeout_seconds: float = 5.0
    deepseek_tool_timeout_seconds: float = 50.0
    vllm_health_timeout_seconds: float = 2.0
    max_tool_calls_per_run: int = 6
    max_message_chars: int = 8_000

    @classmethod
    def from_env(cls) -> "Settings":
        return cls(
            host=os.getenv("AGENT_HOST", "127.0.0.1").strip() or "127.0.0.1",
            port=_env_int("AGENT_PORT", 7861),
            model_name=os.getenv("MODEL_NAME", "Qwen/Qwen3-VL-2B-Instruct").strip(),
            model_server=os.getenv("MODEL_SERVER", "http://127.0.0.1:8000/v1").rstrip("/"),
            api_key=os.getenv("API_KEY", "EMPTY"),
            tool_timeout_seconds=_env_float("AGENT_TOOL_TIMEOUT", 5.0, minimum=0.1),
            deepseek_tool_timeout_seconds=_env_float(
                "AGENT_DEEPSEEK_TOOL_TIMEOUT",
                50.0,
                minimum=0.1,
            ),
            vllm_health_timeout_seconds=_env_float("VLLM_HEALTH_TIMEOUT", 2.0, minimum=0.1),
            max_tool_calls_per_run=_env_int("AGENT_MAX_TOOL_CALLS", 6),
            max_message_chars=_env_int("AGENT_MAX_MESSAGE_CHARS", 8_000),
        )

    @property
    def models_url(self) -> str:
        return f"{self.model_server}/models"
