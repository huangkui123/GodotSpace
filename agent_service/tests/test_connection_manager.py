from __future__ import annotations

import asyncio
import unittest
from typing import Any

from agent_service.connection_manager import (
    ConnectionManager,
    GodotToolTimeoutError,
    GodotUnavailableError,
)
from agent_service.protocol import make_envelope


class FakeWebSocket:
    def __init__(self) -> None:
        self.sent: list[dict[str, Any]] = []

    async def send_json(self, data: dict[str, Any]) -> None:
        self.sent.append(data)


class ConnectionManagerTests(unittest.IsolatedAsyncioTestCase):
    async def test_tool_result_is_correlated(self) -> None:
        manager = ConnectionManager()
        websocket = FakeWebSocket()
        await manager.register("session-1", "godot", websocket)

        task = asyncio.create_task(
            manager.request_tool(
                "session-1",
                "request-1",
                "open_album",
                {"page": 1},
                1.0,
            )
        )
        await asyncio.sleep(0)
        call = websocket.sent[-1]
        self.assertEqual(call["type"], "tool_call")
        self.assertEqual(call["payload"]["name"], "open_album")

        result = make_envelope(
            "tool_result",
            {"ok": True, "data": {"visible": True}, "error": None},
            session_id="session-1",
            request_id="request-1",
            tool_call_id=call["tool_call_id"],
        )
        self.assertTrue(await manager.resolve_tool_result("session-1", result))
        self.assertTrue((await task)["ok"])

    async def test_unknown_session_is_rejected(self) -> None:
        manager = ConnectionManager()
        with self.assertRaises(GodotUnavailableError):
            await manager.request_tool(
                "missing", "request-1", "open_album", {}, 0.1
            )

    async def test_tool_call_times_out(self) -> None:
        manager = ConnectionManager()
        await manager.register("session-1", "godot", FakeWebSocket())
        with self.assertRaises(GodotToolTimeoutError):
            await manager.request_tool(
                "session-1", "request-1", "open_album", {}, 0.01
            )

    async def test_disconnect_fails_pending_call(self) -> None:
        manager = ConnectionManager()
        websocket = FakeWebSocket()
        await manager.register("session-1", "godot", websocket)
        task = asyncio.create_task(
            manager.request_tool(
                "session-1", "request-1", "open_album", {}, 1.0
            )
        )
        await asyncio.sleep(0)
        await manager.unregister("session-1", websocket)
        with self.assertRaises(GodotUnavailableError):
            await task


if __name__ == "__main__":
    unittest.main()
