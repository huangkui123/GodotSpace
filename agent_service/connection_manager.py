from __future__ import annotations

import asyncio
import concurrent.futures
from dataclasses import dataclass, field
from typing import Any

from agent_service.protocol import make_envelope, new_id, validate_tool_result_payload


class GodotConnectionError(RuntimeError):
    """Base class for Godot RPC transport failures."""


class GodotUnavailableError(GodotConnectionError):
    """Raised when no Godot websocket is registered for a session."""


class GodotToolTimeoutError(GodotConnectionError):
    """Raised when Godot does not answer a tool call before its deadline."""


@dataclass(slots=True)
class PendingToolCall:
    request_id: str
    future: asyncio.Future[dict[str, Any]]


@dataclass(slots=True)
class GodotConnection:
    session_id: str
    client_id: str
    websocket: Any
    send_lock: asyncio.Lock = field(default_factory=asyncio.Lock)
    pending_calls: dict[str, PendingToolCall] = field(default_factory=dict)


class ConnectionManager:
    def __init__(self) -> None:
        self._connections: dict[str, GodotConnection] = {}
        self._lock = asyncio.Lock()
        self._event_loop: asyncio.AbstractEventLoop | None = None

    async def register(self, session_id: str, client_id: str, websocket: Any) -> None:
        loop = asyncio.get_running_loop()
        async with self._lock:
            previous = self._connections.pop(session_id, None)
            if previous is not None:
                self._fail_pending(
                    previous,
                    GodotUnavailableError("Godot client was replaced by a newer connection"),
                )
            self._connections[session_id] = GodotConnection(
                session_id=session_id,
                client_id=client_id,
                websocket=websocket,
            )
            self._event_loop = loop

    async def unregister(self, session_id: str, websocket: Any | None = None) -> None:
        async with self._lock:
            connection = self._connections.get(session_id)
            if connection is None:
                return
            if websocket is not None and connection.websocket is not websocket:
                return
            self._connections.pop(session_id, None)
            self._fail_pending(
                connection,
                GodotUnavailableError("Godot client disconnected during tool execution"),
            )

    async def is_connected(self, session_id: str) -> bool:
        async with self._lock:
            return session_id in self._connections

    async def connected_count(self) -> int:
        async with self._lock:
            return len(self._connections)

    async def send_event(
        self,
        session_id: str,
        message_type: str,
        payload: dict[str, Any] | None = None,
        *,
        request_id: str = "",
        tool_call_id: str = "",
    ) -> None:
        connection = await self._get_connection(session_id)
        envelope = make_envelope(
            message_type,
            payload,
            session_id=session_id,
            request_id=request_id,
            tool_call_id=tool_call_id,
        )
        async with connection.send_lock:
            try:
                await connection.websocket.send_json(envelope)
            except Exception as exc:
                raise GodotUnavailableError(f"Unable to send data to Godot: {exc}") from exc

    async def request_tool(
        self,
        session_id: str,
        request_id: str,
        tool_name: str,
        arguments: dict[str, Any],
        timeout_seconds: float,
    ) -> dict[str, Any]:
        connection = await self._get_connection(session_id)
        tool_call_id = new_id("tool")
        loop = asyncio.get_running_loop()
        pending = PendingToolCall(request_id=request_id, future=loop.create_future())
        connection.pending_calls[tool_call_id] = pending
        try:
            await self.send_event(
                session_id,
                "tool_call",
                {"name": tool_name, "arguments": arguments},
                request_id=request_id,
                tool_call_id=tool_call_id,
            )
            try:
                return await asyncio.wait_for(pending.future, timeout=timeout_seconds)
            except TimeoutError as exc:
                raise GodotToolTimeoutError(
                    f"Godot tool {tool_name!r} timed out after {timeout_seconds:.1f}s"
                ) from exc
        finally:
            connection.pending_calls.pop(tool_call_id, None)

    def request_tool_sync(
        self,
        session_id: str,
        request_id: str,
        tool_name: str,
        arguments: dict[str, Any],
        timeout_seconds: float,
    ) -> dict[str, Any]:
        loop = self._event_loop
        if loop is None or loop.is_closed():
            raise GodotUnavailableError("Godot RPC event loop is not available")
        future = asyncio.run_coroutine_threadsafe(
            self.request_tool(
                session_id=session_id,
                request_id=request_id,
                tool_name=tool_name,
                arguments=arguments,
                timeout_seconds=timeout_seconds,
            ),
            loop,
        )
        try:
            return future.result(timeout=timeout_seconds + 1.0)
        except concurrent.futures.TimeoutError as exc:
            future.cancel()
            raise GodotToolTimeoutError(
                f"Godot tool {tool_name!r} exceeded its synchronous RPC deadline"
            ) from exc

    async def resolve_tool_result(self, session_id: str, envelope: dict[str, Any]) -> bool:
        connection = await self._get_connection(session_id)
        tool_call_id = envelope.get("tool_call_id", "")
        if not tool_call_id:
            return False
        pending = connection.pending_calls.get(tool_call_id)
        if pending is None or pending.future.done():
            return False
        if envelope.get("request_id", "") != pending.request_id:
            return False
        validate_tool_result_payload(envelope["payload"])
        pending.future.set_result(envelope["payload"])
        return True

    async def cancel_request(self, session_id: str, request_id: str) -> int:
        connection = await self._get_connection(session_id)
        cancelled = 0
        for pending in list(connection.pending_calls.values()):
            if pending.request_id == request_id and not pending.future.done():
                pending.future.cancel()
                cancelled += 1
        return cancelled

    async def _get_connection(self, session_id: str) -> GodotConnection:
        async with self._lock:
            connection = self._connections.get(session_id)
        if connection is None:
            raise GodotUnavailableError(f"No Godot client is connected for session {session_id!r}")
        return connection

    @staticmethod
    def _fail_pending(connection: GodotConnection, error: Exception) -> None:
        for pending in connection.pending_calls.values():
            if not pending.future.done():
                pending.future.set_exception(error)
        connection.pending_calls.clear()
