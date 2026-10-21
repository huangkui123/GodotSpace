"""Real ENet Server/two Clients + one mock Gateway; no inference or audio devices."""
from __future__ import annotations

import argparse
import asyncio
import json
import os

from websockets.asyncio.server import serve


async def run(args: argparse.Namespace) -> None:
    rounds = 0
    connections = 0
    children = []
    errors = []

    async def gateway(connection):
        nonlocal rounds, connections
        connections += 1

        async def send(kind, payload, request="", tool=""):
            await connection.send(json.dumps(dict(protocol_version="1.0", session_id="server-test", type=kind,
                payload=payload, request_id=request, tool_call_id=tool, timestamp_ms=0)))
        try:
            async for raw in connection:
                msg = json.loads(raw)
                if msg["type"] == "hello":
                    await send("hello_ack", {})
                elif msg["type"] == "ping":
                    await send("pong", {})
                elif msg["type"] == "user_message":
                    text = msg["payload"]["text"]
                    assert "相册" not in text, "stale pre-click transcript reached model"
                    opening = "打开" in text
                    name = "open_task_guide" if opening else "go_to_task_guide_page"
                    assert name in msg["payload"]["allowed_tools"]
                    await send("tool_call", {"name": name, "arguments": {"task_id": 1} if opening else {"page": 2}}, msg["request_id"], msg["request_id"] + "-tool")
                elif msg["type"] == "tool_result":
                    assert msg["payload"]["ok"], msg["payload"]
                    rounds += 1
                    await send("assistant_final", {"answer": "目标操作完成", "route": "tool_executed"}, msg["request_id"])
        except Exception as exc:
            errors.append(str(exc))

    async def launch(role):
        env = dict(os.environ, GODOTSPACE_AGENT_ENDPOINT="ws://127.0.0.1:18761/ws/godot")
        env["WSLENV"] = ":".join(filter(None, [env.get("WSLENV", ""), "GODOTSPACE_AGENT_ENDPOINT"]))
        argv = [args.godot, "--headless", "--path", args.project, "--script",
                "res://Assets/ARSpace/Scripts/AI/LocalAgent/server_hosted_e2e_self_test.gd", "--"]
        if role == "server":
            argv.append("--endpoint-test-server")
        child = await asyncio.create_subprocess_exec(*argv, env=env, stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.STDOUT)
        children.append(child)
        output, _ = await asyncio.wait_for(child.communicate(), 40)
        text = output.decode("utf-8", errors="replace")
        for line in text.splitlines():
            if any(word in line for word in ("ERROR", "failed", "FAILED", "passed", " at:")):
                print(f"{role}: {line}")
        assert child.returncode == 0 and "E2E" in text and "passed" in text and "SCRIPT ERROR" not in text, text[-6000:]

    async with serve(gateway, "127.0.0.1", 18761):
        tasks = [asyncio.create_task(launch("server"))]
        try:
            await asyncio.sleep(0.8)
            tasks.extend([asyncio.create_task(launch("sky")), asyncio.create_task(launch("ground"))])
            await asyncio.gather(*tasks)
            assert not errors, errors
            assert rounds == 4 and connections == 1, (rounds, connections)
            print("Centralized routing: one Gateway, two Clients, four targeted tool rounds, stale audio and disconnect PASS")
        finally:
            for child in children:
                if child.returncode is None:
                    child.terminate()
            await asyncio.gather(*(c.wait() for c in children), return_exceptions=True)
            await asyncio.gather(*tasks, return_exceptions=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--godot", required=True)
    parser.add_argument("--project", required=True)
    asyncio.run(run(parser.parse_args()))
