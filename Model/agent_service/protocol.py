from __future__ import annotations

import time
from typing import Any, Final
from uuid import uuid4


PROTOCOL_VERSION: Final = "1.0"
MESSAGE_TYPES: Final = frozenset(
    {
        "hello",
        "hello_ack",
        "user_message",
        "run_started",
        "tool_call",
        "tool_result",
        "assistant_final",
        "run_error",
        "cancel_run",
        "confirmation_update",
        "confirmation_state",
        "ping",
        "pong",
    }
)


class ProtocolError(ValueError):
    """Raised when a websocket envelope violates the gateway protocol."""


def new_id(prefix: str) -> str:
    return f"{prefix}-{uuid4().hex}"


def make_envelope(
    message_type: str,
    payload: dict[str, Any] | None = None,
    *,
    session_id: str = "",
    request_id: str = "",
    tool_call_id: str = "",
) -> dict[str, Any]:
    if message_type not in MESSAGE_TYPES:
        raise ProtocolError(f"Unsupported message type: {message_type}")
    return {
        "protocol_version": PROTOCOL_VERSION,
        "type": message_type,
        "session_id": session_id,
        "request_id": request_id,
        "tool_call_id": tool_call_id,
        "timestamp_ms": int(time.time() * 1000),
        "payload": payload or {},
    }


def parse_envelope(raw: Any) -> dict[str, Any]:
    if not isinstance(raw, dict):
        raise ProtocolError("Message must be a JSON object")

    version = raw.get("protocol_version")
    if version != PROTOCOL_VERSION:
        raise ProtocolError(
            f"Unsupported protocol_version {version!r}; expected {PROTOCOL_VERSION!r}"
        )

    message_type = raw.get("type")
    if not isinstance(message_type, str) or message_type not in MESSAGE_TYPES:
        raise ProtocolError(f"Unsupported message type: {message_type!r}")

    payload = raw.get("payload", {})
    if not isinstance(payload, dict):
        raise ProtocolError("payload must be a JSON object")

    parsed = dict(raw)
    parsed["payload"] = payload
    for key in ("session_id", "request_id", "tool_call_id"):
        value = parsed.get(key, "")
        if not isinstance(value, str):
            raise ProtocolError(f"{key} must be a string")
        parsed[key] = value.strip()
    return parsed


def require_payload_string(
    envelope: dict[str, Any],
    name: str,
    *,
    max_chars: int | None = None,
) -> str:
    value = envelope["payload"].get(name)
    if not isinstance(value, str) or not value.strip():
        raise ProtocolError(f"payload.{name} must be a non-empty string")
    value = value.strip()
    if max_chars is not None and len(value) > max_chars:
        raise ProtocolError(f"payload.{name} exceeds the {max_chars} character limit")
    return value


def validate_tool_result_payload(payload: dict[str, Any]) -> None:
    ok = payload.get("ok")
    if not isinstance(ok, bool):
        raise ProtocolError("tool_result payload.ok must be a boolean")
    data = payload.get("data", {})
    if not isinstance(data, dict):
        raise ProtocolError("tool_result payload.data must be a JSON object")
    error = payload.get("error")
    if error is not None and not isinstance(error, dict):
        raise ProtocolError("tool_result payload.error must be null or a JSON object")
    if ok and error is not None:
        raise ProtocolError("successful tool_result payload.error must be null")
    if not ok:
        if not isinstance(error, dict):
            raise ProtocolError("failed tool_result payload.error must be an object")
        for field_name in ("code", "message"):
            value = error.get(field_name)
            if not isinstance(value, str) or not value.strip():
                raise ProtocolError(
                    f"tool_result payload.error.{field_name} must be a non-empty string"
                )
