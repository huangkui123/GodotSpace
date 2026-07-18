from __future__ import annotations

import asyncio
import json
import logging
import os
from typing import Any

from websockets.asyncio.server import ServerConnection, serve


SESSION_ID = "session-task-e2e"


def envelope(
    message_type: str,
    payload: dict[str, Any],
    *,
    request_id: str = "",
    tool_call_id: str = "",
) -> str:
    return json.dumps(
        {
            "protocol_version": "1.0",
            "type": message_type,
            "session_id": SESSION_ID,
            "request_id": request_id,
            "tool_call_id": tool_call_id,
            "timestamp_ms": 0,
            "payload": payload,
        },
        ensure_ascii=False,
    )


async def receive_type(connection: ServerConnection, expected: str) -> dict[str, Any]:
    while True:
        message = json.loads(await asyncio.wait_for(connection.recv(), timeout=8.0))
        if message.get("type") == "ping":
            await connection.send(envelope("pong", message.get("payload", {})))
            continue
        if message.get("type") == expected:
            return message


async def run_tool_round(
    connection: ServerConnection,
    *,
    expected_text: str,
    tool_name: str,
    tool_call_id: str,
    expected_page: int,
    answer: str,
) -> None:
    request = await receive_type(connection, "user_message")
    payload = request["payload"]
    if expected_text not in payload.get("text", ""):
        raise RuntimeError(f"unexpected transcript: {payload}")
    if payload.get("allowed_tools") != [tool_name]:
        raise RuntimeError(f"unexpected tool authorization: {payload}")
    context = payload.get("context", {})
    if "speaker_peer_id" in context:
        raise RuntimeError("speaker_peer_id leaked into the Gateway context")
    if context.get("page_index") != expected_page:
        raise RuntimeError(f"unexpected task snapshot: {context}")

    request_id = request["request_id"]
    await connection.send(
        envelope(
            "tool_call",
            {"name": tool_name, "arguments": {}},
            request_id=request_id,
            tool_call_id=tool_call_id,
        )
    )
    result = await receive_type(connection, "tool_result")
    if not result["payload"].get("ok"):
        raise RuntimeError(f"{tool_name} failed: {result['payload']}")
    result_data = result["payload"].get("data", {})
    result_snapshot = result_data.get("snapshot", result_data)
    target_page = expected_page + 1 if tool_name == "next_task_step" else expected_page
    if result_snapshot.get("page_index") != target_page:
        raise RuntimeError(f"{tool_name} returned the wrong page: {result_snapshot}")
    await connection.send(
        envelope(
            "assistant_final",
            {"answer": answer, "messages": []},
            request_id=request_id,
        )
    )


async def handle(connection: ServerConnection) -> None:
    await receive_type(connection, "hello")
    await connection.send(envelope("hello_ack", {"client_id": "task-e2e"}))
    await run_tool_round(
        connection,
        expected_text="下一步应该做什么",
        tool_name="get_current_task_step",
        tool_call_id="tool-read",
        expected_page=1,
        answer="下一步是准备工具。",
    )
    await run_tool_round(
        connection,
        expected_text="进入下一步",
        tool_name="next_task_step",
        tool_call_id="tool-advance",
        expected_page=1,
        answer="已进入下一步。",
    )
    await asyncio.sleep(0.5)


async def run_dynamic_round(
    connection: ServerConnection,
    *,
    tool_name: str,
    tool_call_id: str,
    answer: str,
) -> tuple[int, int]:
    request = await receive_type(connection, "user_message")
    payload = request["payload"]
    if payload.get("allowed_tools") != [tool_name]:
        raise RuntimeError(f"unexpected tool authorization: {payload}")
    context = payload.get("context", {})
    if "speaker_peer_id" in context:
        raise RuntimeError("speaker_peer_id leaked into the Gateway context")
    source_page = int(context.get("page_index", 0))
    if source_page <= 0:
        raise RuntimeError(f"missing task page context: {context}")
    request_id = request["request_id"]
    await connection.send(
        envelope(
            "tool_call",
            {"name": tool_name, "arguments": {}},
            request_id=request_id,
            tool_call_id=tool_call_id,
        )
    )
    result = await receive_type(connection, "tool_result")
    if not result["payload"].get("ok"):
        raise RuntimeError(f"{tool_name} failed: {result['payload']}")
    data = result["payload"].get("data", {})
    snapshot = data.get("snapshot", data)
    result_page = int(snapshot.get("page_index", 0))
    await connection.send(
        envelope(
            "assistant_final",
            {"answer": answer, "messages": []},
            request_id=request_id,
        )
    )
    return source_page, result_page


async def handle_multi_client(connection: ServerConnection) -> None:
    await receive_type(connection, "hello")
    await connection.send(envelope("hello_ack", {"client_id": "task-multi-e2e"}))
    pages: list[int] = []
    for index in range(2):
        source_page, result_page = await run_dynamic_round(
            connection,
            tool_name="get_current_task_step",
            tool_call_id=f"tool-read-{index}",
            answer=f"已读取说话者 {index + 1} 的步骤。",
        )
        if result_page != source_page:
            raise RuntimeError("read-only query changed a Client task page")
        pages.append(source_page)
    if sorted(pages) != [1, 2]:
        raise RuntimeError(f"speaker snapshots crossed or were stale: {pages}")

    for index, expected_page in enumerate(pages):
        source_page, result_page = await run_dynamic_round(
            connection,
            tool_name="next_task_step",
            tool_call_id=f"tool-advance-{index}",
            answer=f"已推进说话者 {index + 1} 的步骤。",
        )
        if source_page != expected_page or result_page != expected_page + 1:
            raise RuntimeError(
                f"speaker {index + 1} advanced incorrectly: "
                f"context={source_page}, result={result_page}, expected={expected_page}"
            )
    await asyncio.sleep(0.5)


async def run_open_round(
    connection: ServerConnection,
    *,
    tool_name: str,
    tool_call_id: str,
    arguments: dict[str, Any],
) -> dict[str, Any]:
    request = await receive_type(connection, "user_message")
    payload = request["payload"]
    if payload.get("allowed_tools") != [tool_name]:
        raise RuntimeError(f"unexpected open tool authorization: {payload}")
    if "speaker_peer_id" in payload.get("context", {}):
        raise RuntimeError("speaker_peer_id leaked into the Gateway context")
    request_id = request["request_id"]
    await connection.send(
        envelope(
            "tool_call",
            {"name": tool_name, "arguments": arguments},
            request_id=request_id,
            tool_call_id=tool_call_id,
        )
    )
    result = await receive_type(connection, "tool_result")
    if not result["payload"].get("ok"):
        raise RuntimeError(f"{tool_name} failed: {result['payload']}")
    await connection.send(
        envelope(
            "assistant_final",
            {"answer": f"{tool_name} 已执行。", "messages": []},
            request_id=request_id,
        )
    )
    return result["payload"].get("data", {})


async def handle_remote_full(connection: ServerConnection) -> None:
    await receive_type(connection, "hello")
    await connection.send(envelope("hello_ack", {"client_id": "task-remote-full"}))
    album_data = await run_open_round(
        connection,
        tool_name="open_album",
        tool_call_id="tool-open-album",
        arguments={"page": 1, "refresh": True},
    )
    if not album_data.get("visible"):
        raise RuntimeError(f"remote album did not become visible: {album_data}")
    guide_data = await run_open_round(
        connection,
        tool_name="open_task_guide",
        tool_call_id="tool-open-guide",
        arguments={"task_id": 1},
    )
    guide_snapshot = guide_data.get("snapshot", {})
    if guide_snapshot.get("task_id") != 1 or guide_snapshot.get("page_index") != 1:
        raise RuntimeError(f"remote task guide did not open at page 1: {guide_data}")
    await run_tool_round(
        connection,
        expected_text="下一步应该做什么",
        tool_name="get_current_task_step",
        tool_call_id="tool-read",
        expected_page=1,
        answer="下一步是准备工具。",
    )
    await run_tool_round(
        connection,
        expected_text="进入下一步",
        tool_name="next_task_step",
        tool_call_id="tool-advance",
        expected_page=1,
        answer="已进入下一步。",
    )
    await asyncio.sleep(0.5)


async def main() -> None:
    completed = asyncio.get_running_loop().create_future()
    quiet_logger = logging.getLogger("mock-task-agent-gateway")
    quiet_logger.disabled = True

    async def tracked_handle(connection: ServerConnection) -> None:
        try:
            scenario = os.environ.get("TASK_AGENT_SCENARIO")
            if scenario == "multi":
                await handle_multi_client(connection)
            elif scenario == "remote_full":
                await handle_remote_full(connection)
            else:
                await handle(connection)
        except BaseException as exc:
            if not completed.done():
                completed.set_exception(exc)
            raise
        else:
            if not completed.done():
                completed.set_result(None)

    async with serve(tracked_handle, "127.0.0.1", 7861, logger=quiet_logger):
        scenario = os.environ.get("TASK_AGENT_SCENARIO", "single")
        print(f"Mock task Agent Gateway ({scenario}) listening on ws://127.0.0.1:7861")
        await completed


if __name__ == "__main__":
    asyncio.run(main())
