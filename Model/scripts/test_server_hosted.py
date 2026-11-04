"""Real ENet Server/Clients + Gateway fixture; optionally prove Sky needs no Ground."""
from __future__ import annotations

import argparse
import asyncio
import json
import os
from contextlib import asynccontextmanager
from pathlib import Path
import socket
import sys

from websockets.asyncio.server import serve


async def run(args: argparse.Namespace) -> None:
    rounds = 0
    connections = 0
    children = []
    errors = []
    client_count = 1 if getattr(args, "sky_only", False) else 2
    live_gateway = getattr(args, "gateway_endpoint", None)

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
        env = dict(os.environ, GODOTSPACE_AGENT_ENDPOINT=live_gateway or "ws://127.0.0.1:18761/ws/godot")
        env["WSLENV"] = ":".join(filter(None, [env.get("WSLENV", ""), "GODOTSPACE_AGENT_ENDPOINT"]))
        argv = [args.godot, "--headless", "--path", args.project, "--script",
                "res://Assets/ARSpace/Scripts/AI/LocalAgent/server_hosted_e2e_self_test.gd", "--"]
        if role == "server":
            argv.append("--endpoint-test-server")
        if getattr(args, "sky_only", False):
            argv.append("--sky-only")
        if live_gateway:
            argv.append("--live-model")
        child = await asyncio.create_subprocess_exec(*argv, env=env, stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.STDOUT)
        children.append(child)
        output, _ = await asyncio.wait_for(child.communicate(), 140 if live_gateway else 40)
        text = output.decode("utf-8", errors="replace")
        for line in text.splitlines():
            if any(word in line for word in ("ERROR", "failed", "FAILED", "passed", " at:")):
                print(f"{role}: {line}")
        assert child.returncode == 0 and "E2E" in text and "passed" in text and "SCRIPT ERROR" not in text, text[-6000:]

    @asynccontextmanager
    async def gateway_context():
        if live_gateway:
            # Explicit opt-in: exercise an already-running Gateway/model, never start or stop it.
            yield
            return
        if not getattr(args, "external_model_fixture", False):
            async with serve(gateway, "127.0.0.1", 18761):
                yield
            return
        sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
        import uvicorn
        from agent_service.app import create_app
        from agent_service.tests.test_external_model import model_server
        from qwen_agent.agents import FnCallAgent  # preload dependencies before timed Godot fixtures
        with model_server() as (settings, state), socket.socket() as listener:
            listener.bind(("127.0.0.1", 18761)) # fail on conflict, never evict
            app = create_app(settings)
            server = uvicorn.Server(uvicorn.Config(app, log_level="error", access_log=False))
            serving = asyncio.create_task(server.serve(sockets=[listener]))
            try:
                while not server.started:
                    if serving.done():
                        await serving
                        raise RuntimeError("Fixture Gateway did not start")
                    await asyncio.sleep(0.05)
                yield
                assert state["selected"].count("open_task_guide") == client_count, state["selected"]
                assert state["selected"].count("go_to_task_guide_page") == client_count, state["selected"]
                assert all(auth == "Bearer synthetic-key" for _, auth, _ in state["requests"])
            finally:
                server.should_exit = True
                await serving

    async with gateway_context():
        tasks = [asyncio.create_task(launch("server"))]
        try:
            await asyncio.sleep(0.8)
            tasks.append(asyncio.create_task(launch("sky")))
            if client_count == 2:
                tasks.append(asyncio.create_task(launch("ground")))
            await asyncio.gather(*tasks)
            assert not errors, errors
            if not live_gateway and not getattr(args, "external_model_fixture", False):
                assert rounds == client_count * 2 and connections == 1, (rounds, connections)
            print(f"Centralized routing: {client_count} Client(s), {client_count * 2} targeted tool rounds, stale audio and disconnect PASS" +
                  ("; NO Ground process was started" if client_count == 1 else "") +
                  (" (existing live Gateway/model)" if live_gateway else
                   " (REAL Gateway/harness + fixture OpenAI-compatible model)" if getattr(args, "external_model_fixture", False) else " (mock Gateway)"))
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
    backend = parser.add_mutually_exclusive_group()
    backend.add_argument("--external-model-fixture", action="store_true")
    backend.add_argument("--gateway-endpoint", help="Explicitly test an existing live Gateway/model; may perform inference")
    parser.add_argument("--sky-only", action="store_true", help="Run only Server + Sky; never create a Ground process")
    asyncio.run(run(parser.parse_args()))
