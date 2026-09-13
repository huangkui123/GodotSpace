#!/usr/bin/env python3
from __future__ import annotations

import asyncio
import json
import sys
from pathlib import Path

from websockets.asyncio.client import connect

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from agent_service.protocol import make_envelope


async def main() -> int:
    session_id = "remote-model-smoke"
    request_id = "remote-model-open-album"
    async with connect("ws://127.0.0.1:7861/ws/godot", open_timeout=10) as socket:
        await socket.send(
            json.dumps(
                make_envelope(
                    "hello",
                    {"client_id": "remote-model-smoke"},
                    session_id=session_id,
                )
            )
        )
        hello = json.loads(await asyncio.wait_for(socket.recv(), timeout=10))
        if hello["type"] != "hello_ack":
            raise RuntimeError(f"Expected hello_ack, got {hello}")

        await socket.send(
            json.dumps(
                make_envelope(
                    "user_message",
                    {"text": "打开相册", "allowed_tools": ["open_album"]},
                    session_id=session_id,
                    request_id=request_id,
                )
            )
        )

        while True:
            message = json.loads(await asyncio.wait_for(socket.recv(), timeout=90))
            message_type = message["type"]
            if message_type == "tool_call":
                if message["payload"].get("name") != "open_album":
                    raise RuntimeError(f"Expected open_album, got {message}")
                await socket.send(
                    json.dumps(
                        make_envelope(
                            "tool_result",
                            {"ok": True, "data": {"opened": True}},
                            session_id=session_id,
                            request_id=request_id,
                            tool_call_id=message["tool_call_id"],
                        )
                    )
                )
            elif message_type == "assistant_final":
                print(json.dumps(message["payload"], ensure_ascii=False))
                return 0
            elif message_type == "run_error":
                raise RuntimeError(message["payload"])


if __name__ == "__main__":
    try:
        raise SystemExit(asyncio.run(main()))
    except Exception as exc:
        print(f"Remote model tool-call smoke test failed: {exc}", file=sys.stderr)
        raise SystemExit(1)
