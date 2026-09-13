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
            "session_id": "session-album-demo",
            "request_id": request_id,
            "tool_call_id": tool_call_id,
            "timestamp_ms": 0,
            "payload": payload,
        },
        ensure_ascii=False,
    )


async def receive_type(connection: ServerConnection, expected: str) -> dict[str, Any]:
    while True:
        message = json.loads(await connection.recv())
        if message.get("type") == "ping":
            await connection.send(envelope("pong", message.get("payload", {})))
        elif message.get("type") == expected:
            return message


async def handle(connection: ServerConnection) -> None:
    await receive_type(connection, "hello")
    await connection.send(envelope("hello_ack", {"client_id": "album-demo"}))

    result: dict[str, Any] | None = None
    for attempt in range(20):
        request_id = f"request-album-demo-{attempt}"
        tool_call_id = f"tool-album-demo-{attempt}"
        await connection.send(
            envelope(
                "tool_call",
                {"name": "open_album", "arguments": {"page": 1, "refresh": True}},
                request_id=request_id,
                tool_call_id=tool_call_id,
            )
        )
        message = await receive_type(connection, "tool_result")
        result = message["payload"]
        if result.get("ok"):
            await connection.send(
                envelope(
                    "assistant_final",
                    {"answer": "相册已通过 Local Agent 打开。", "messages": []},
                    request_id=request_id,
                )
            )
            print(json.dumps(result, ensure_ascii=False), flush=True)
            break
        await asyncio.sleep(0.5)
    else:
        raise RuntimeError(f"Album did not become ready: {result}")

    while True:
        try:
            await receive_type(connection, "__never__")
        except Exception:
            return


async def main() -> None:
    done = asyncio.Event()

    async def run_once(connection: ServerConnection) -> None:
        try:
            await handle(connection)
        finally:
            done.set()

    async with serve(run_once, "127.0.0.1", 7861):
        print("Album demo Gateway ready", flush=True)
        await done.wait()


if __name__ == "__main__":
    asyncio.run(main())
