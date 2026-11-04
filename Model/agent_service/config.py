from __future__ import annotations

import os
import math
from dataclasses import dataclass


DEFAULT_KNOWLEDGE_RUNTIME_SOURCE = "当前专家任务步骤 / 本地客户端"


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
    if not math.isfinite(value) or value < minimum:
        raise ValueError(f"{name} must be >= {minimum}, got {value}")
    return value


def _env_bool(name: str, default: bool) -> bool:
    raw = os.getenv(name, str(default)).strip().lower()
    if raw in {"1", "true", "yes", "on"}:
        return True
    if raw in {"0", "false", "no", "off"}:
        return False
    raise ValueError(f"{name} must be a boolean, got {raw!r}")


def _env_optional_bool(name: str) -> bool | None:
    raw = os.getenv(name, "").strip()
    if not raw:
        return None
    return _env_bool(name, False)


@dataclass(frozen=True, slots=True)
class Settings:
    host: str = "127.0.0.1"
    port: int = 7861
    model_name: str = "Qwen/Qwen3-VL-2B-Instruct"
    model_server: str = "http://127.0.0.1:8000/v1"
    api_key: str = "EMPTY"
    model_type: str = "qwenvl_oai"
    model_use_raw_api: bool = False
    model_fncall_prompt_type: str = "nous"
    model_enable_thinking: bool | None = None
    model_health_check: str = "models"
    model_json_mode: str = "json_schema"
    model_backend: str = "qwen_agent"
    tool_timeout_seconds: float = 5.0
    knowledge_context_tool_timeout_seconds: float = 5.0
    vllm_health_timeout_seconds: float = 2.0
    max_tool_calls_per_run: int = 6
    max_message_chars: int = 8_000
    knowledge_retrieval_limit: int = 5
    knowledge_minimum_score: float = 2.0
    knowledge_model_timeout_seconds: float = 2.0
    tool_semantic_timeout_seconds: float = 10.0
    model_request_timeout_seconds: float = 20.0
    run_timeout_seconds: float = 45.0
    knowledge_corpus_path: str = ""
    knowledge_runtime_source: str = DEFAULT_KNOWLEDGE_RUNTIME_SOURCE

    @classmethod
    def from_env(cls) -> "Settings":
        health_check = os.getenv("MODEL_HEALTH_CHECK", "models")
        json_mode = os.getenv("MODEL_JSON_MODE", "json_schema")
        backend = os.getenv("MODEL_BACKEND", "qwen_agent")
        if backend not in {"qwen_agent", "openai"}:
            raise ValueError("MODEL_BACKEND must be qwen_agent or openai")
        if health_check not in {"models", "chat"}:
            raise ValueError("MODEL_HEALTH_CHECK must be models or chat")
        if json_mode not in {"json_schema", "json_object", "prompt"}:
            raise ValueError("MODEL_JSON_MODE must be json_schema, json_object or prompt")
        return cls(
            host=os.getenv("AGENT_HOST", "127.0.0.1").strip() or "127.0.0.1",
            port=_env_int("AGENT_PORT", 7861),
            model_name=os.getenv("MODEL_NAME", "Qwen/Qwen3-VL-2B-Instruct").strip(),
            model_server=os.getenv("MODEL_SERVER", "http://127.0.0.1:8000/v1").rstrip("/"),
            api_key=os.getenv("API_KEY", "EMPTY"),
            model_type=os.getenv("MODEL_TYPE", "qwenvl_oai").strip() or "qwenvl_oai",
            model_use_raw_api=_env_bool("MODEL_USE_RAW_API", False),
            model_fncall_prompt_type=(
                os.getenv("MODEL_FNCALL_PROMPT_TYPE", "nous").strip() or "nous"
            ),
            model_enable_thinking=_env_optional_bool("MODEL_ENABLE_THINKING"),
            model_health_check=health_check,
            model_json_mode=json_mode,
            model_backend=backend,
            tool_timeout_seconds=_env_float("AGENT_TOOL_TIMEOUT", 5.0, minimum=0.1),
            knowledge_context_tool_timeout_seconds=_env_float(
                "AGENT_KNOWLEDGE_CONTEXT_TOOL_TIMEOUT",
                5.0,
                minimum=0.1,
            ),
            vllm_health_timeout_seconds=_env_float("VLLM_HEALTH_TIMEOUT", 2.0, minimum=0.1),
            max_tool_calls_per_run=_env_int("AGENT_MAX_TOOL_CALLS", 6),
            max_message_chars=_env_int("AGENT_MAX_MESSAGE_CHARS", 8_000),
            knowledge_retrieval_limit=_env_int("KNOWLEDGE_RETRIEVAL_LIMIT", 5),
            knowledge_minimum_score=_env_float("KNOWLEDGE_MINIMUM_SCORE", 2.0),
            knowledge_model_timeout_seconds=_env_float(
                "KNOWLEDGE_MODEL_TIMEOUT",
                2.0,
                minimum=0.1,
            ),
            tool_semantic_timeout_seconds=_env_float(
                "TOOL_SEMANTIC_TIMEOUT",
                10.0,
                minimum=0.1,
            ),
            model_request_timeout_seconds=_env_float("AGENT_MODEL_TIMEOUT", 20.0, minimum=0.1),
            run_timeout_seconds=_env_float("AGENT_RUN_TIMEOUT", 45.0, minimum=0.1),
            knowledge_corpus_path=os.getenv("KNOWLEDGE_CORPUS_PATH", "").strip(),
            knowledge_runtime_source=(
                os.getenv(
                    "KNOWLEDGE_RUNTIME_SOURCE",
                    DEFAULT_KNOWLEDGE_RUNTIME_SOURCE,
                ).strip()
                or DEFAULT_KNOWLEDGE_RUNTIME_SOURCE
            ),
        )

    @property
    def models_url(self) -> str:
        return f"{self.model_server}/models"
