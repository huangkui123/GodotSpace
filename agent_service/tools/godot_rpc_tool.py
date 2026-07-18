from __future__ import annotations

import json
from typing import Any

from qwen_agent.tools.base import BaseTool

from agent_service.connection_manager import (
    ConnectionManager,
    GodotConnectionError,
    GodotRequestCancelledError,
    GodotToolTimeoutError,
    GodotUnavailableError,
)


class GodotRpcTool(BaseTool):
    """Base class for a whitelisted tool executed by the connected Godot client."""

    def __init__(
        self,
        connection_manager: ConnectionManager,
        session_id: str,
        request_id: str,
        *,
        timeout_seconds: float,
        max_calls: int,
        state_changing: bool = True,
    ) -> None:
        super().__init__()
        self._connection_manager = connection_manager
        self._session_id = session_id
        self._request_id = request_id
        self._timeout_seconds = timeout_seconds
        self._max_calls = max_calls
        self._state_changing = state_changing
        self._call_count = 0

    def call_godot(self, arguments: dict[str, Any]) -> str:
        self._call_count += 1
        if self._call_count > self._max_calls:
            return json.dumps(
                {
                    "ok": False,
                    "data": {},
                    "error": {
                        "code": "tool_call_limit_exceeded",
                        "message": "The maximum number of tool calls for this run was exceeded.",
                    },
                },
                ensure_ascii=False,
            )
        try:
            result = self._connection_manager.request_tool_sync(
                session_id=self._session_id,
                request_id=self._request_id,
                tool_name=self.name,
                arguments=arguments,
                timeout_seconds=self._timeout_seconds,
                state_changing=self._state_changing,
            )
        except GodotRequestCancelledError as exc:
            result = {
                "ok": False,
                "data": {},
                "error": {"code": "permission_denied", "message": str(exc)},
            }
        except GodotToolTimeoutError as exc:
            result = {
                "ok": False,
                "data": {},
                "error": {"code": "tool_timeout", "message": str(exc)},
            }
        except GodotUnavailableError as exc:
            result = {
                "ok": False,
                "data": {},
                "error": {"code": "target_offline", "message": str(exc)},
            }
        except GodotConnectionError as exc:
            result = {
                "ok": False,
                "data": {},
                "error": {"code": "internal_error", "message": str(exc)},
            }
        return json.dumps(result, ensure_ascii=False)
