"""Isolated mock Gateway + ENet Server/two Client routing regression (not model eval)."""
from __future__ import annotations

import argparse
import asyncio
import json
import os

from websockets.asyncio.server import serve


async def run(args: argparse.Namespace) -> None:
    rounds: dict[int, int] = {18761: 0, 18762: 0}
    errors: list[str] = []

    async def gateway(connection, port: int) -> None:
        session = f"local-test-{port}"

        async def send(kind: str, payload: dict, request: str = "", tool: str = "") -> None:
            await connection.send(json.dumps({
                "protocol_version": "1.0", "session_id": session, "type": kind,
                "payload": payload, "request_id": request, "tool_call_id": tool,
                "timestamp_ms": 0,
            }, ensure_ascii=False))

        try:
            async for raw in connection:
                msg = json.loads(raw)
                kind = msg["type"]
                if kind == "hello":
                    await send("hello_ack", {})
                elif kind == "ping":
                    await send("pong", {})
                elif kind == "user_message":
                    index = rounds[port]
                    assert index < 2, "Unexpected extra request (cross-client wake)"
                    name = "open_task_guide" if index == 0 else "go_to_task_guide_page"
                    assert name in msg["payload"]["allowed_tools"]
                    arguments = {"task_id": 1} if index == 0 else {"page": 2}
                    await send("tool_call", {"name": name, "arguments": arguments}, msg["request_id"], f"tool-{port}-{index}")
                elif kind == "tool_result":
                    assert msg["payload"]["ok"], msg["payload"]
                    rounds[port] += 1
                    await send("assistant_final", {"answer": "本机操作完成", "route": "tool_executed"}, msg["request_id"])
        except Exception as exc:
            errors.append(f"Gateway {port}: {exc}")

    children = []

    async def launch(role: str, port: int) -> tuple[int, str]:
        env = dict(os.environ)
        env["GODOTSPACE_AGENT_ENDPOINT"] = f"ws://127.0.0.1:{port}/ws/godot"
        # Pass the endpoint through WSL interop when launching Windows Godot.
        env["WSLENV"] = ":".join(filter(None, [env.get("WSLENV", ""), "GODOTSPACE_AGENT_ENDPOINT"]))
        cmd = [args.godot, "--headless", "--path", args.project, "--script",
               "res://Assets/ARSpace/Scripts/AI/LocalAgent/local_endpoint_e2e_self_test.gd", "--"]
        if role == "ground":
            cmd.append("--endpoint-test-server")
        process = await asyncio.create_subprocess_exec(*cmd, env=env, stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.STDOUT)
        children.append(process)
        output, _ = await asyncio.wait_for(process.communicate(), 40)
        text = output.decode("utf-8", errors="replace")
        for line in text.splitlines():
            if any(word in line for word in ("ERROR", "failed", "FAILED", "passed", " at:")):
                print(f"{role}: {line}")
        assert process.returncode == 0 and "E2E" in text and "passed" in text and "SCRIPT ERROR" not in text, text[-5000:]
        return process.returncode, text

    async with serve(lambda c: gateway(c, 18761), "127.0.0.1", 18761), serve(lambda c: gateway(c, 18762), "127.0.0.1", 18762):
        tasks = [asyncio.create_task(launch("ground", 18763))]
        try:
            await asyncio.sleep(0.8)
            tasks += [asyncio.create_task(launch("sky-a", 18761)), asyncio.create_task(launch("sky-b", 18762))]
            await asyncio.gather(*tasks)
            assert not errors, errors
            assert rounds == {18761: 2, 18762: 2}, rounds
            print("Local endpoint routing: 2 clients, 4 direct Gateway/tool rounds, ground disconnect PASS")
        finally:
            for child in children:
                if child.returncode is None:
                    child.terminate()
            await asyncio.gather(*(child.wait() for child in children), return_exceptions=True)
            await asyncio.gather(*tasks, return_exceptions=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--godot", required=True)
    parser.add_argument("--project", required=True)
    asyncio.run(run(parser.parse_args()))
