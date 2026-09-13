from __future__ import annotations

import asyncio
import json
from typing import Any

from websockets.asyncio.server import ServerConnection, serve


PROTOCOL_VERSION = "1.0"


def envelope(
    message_type: str,
    payload: dict[str, Any],
    *,
    request_id: str = "",
    tool_call_id: str = "",
) -> str:
    return json.dumps(
        {
            "protocol_version": PROTOCOL_VERSION,
            "type": message_type,
            "session_id": "session-rpc-test",
            "request_id": request_id,
            "tool_call_id": tool_call_id,
            "timestamp_ms": 0,
            "payload": payload,
        }
    )


async def receive_type(connection: ServerConnection, expected: str) -> dict[str, Any]:
    while True:
        message = json.loads(await asyncio.wait_for(connection.recv(), timeout=5.0))
        if message.get("type") == expected:
            return message


async def handle(connection: ServerConnection) -> None:
    hello = await receive_type(connection, "hello")
    if hello.get("protocol_version") != PROTOCOL_VERSION:
        raise RuntimeError("Godot sent an unsupported protocol version")
    await connection.send(envelope("hello_ack", {"client_id": "rpc-test"}))
    await connection.send(envelope("pong", {"server_time_msec": 0}))
    await asyncio.sleep(0.25)

    tool_call = envelope(
        "tool_call",
        {"name": "open_album", "arguments": {"page": 1, "refresh": True}},
        request_id="request-rpc-test",
        tool_call_id="tool-rpc-test",
    )
    await connection.send(tool_call)
    first = await receive_type(connection, "tool_result")
    await connection.send(
        envelope(
            "tool_call",
            {"name": "open_album", "arguments": {"page": 9, "refresh": False}},
            request_id="request-rpc-test",
            tool_call_id="tool-rpc-test",
        )
    )
    duplicate = await receive_type(connection, "tool_result")
    if not first["payload"].get("ok"):
        raise RuntimeError(f"open_album failed: {first['payload']}")
    if first["payload"] != duplicate["payload"]:
        raise RuntimeError("duplicate tool_call_id did not replay the cached result")
    if first["payload"]["data"].get("page") != 1:
        raise RuntimeError("open_album page was not preserved")

    await connection.send(
        envelope(
            "tool_call",
            {"name": "different_tool", "arguments": {}},
            request_id="different-request",
            tool_call_id="tool-rpc-test",
        )
    )
    conflict = await receive_type(connection, "tool_result")
    if conflict["payload"].get("error", {}).get("code") != "tool_call_conflict":
        raise RuntimeError("conflicting duplicate tool_call_id was not rejected")

    await connection.send(
        envelope(
            "assistant_final",
            {"answer": "rpc-test-passed", "messages": []},
            request_id="request-rpc-test",
        )
    )
    await asyncio.sleep(0.1)
    await connection.send("x" * 262_145)
    await asyncio.wait_for(connection.wait_closed(), timeout=5.0)


async def main() -> None:
    async with serve(handle, "127.0.0.1", 7861):
        print("Mock Godot tool Gateway listening on ws://127.0.0.1:7861")
        await asyncio.Future()


if __name__ == "__main__":
    asyncio.run(main())
