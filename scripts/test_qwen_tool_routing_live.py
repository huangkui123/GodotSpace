#!/usr/bin/env python3
from __future__ import annotations

import argparse
import asyncio
import json
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Any
from uuid import uuid4

import websockets

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from agent_service.protocol import make_envelope


@dataclass(frozen=True, slots=True)
class RoutingCase:
    name: str
    text: str
    context: dict[str, Any]
    allowed_tools: list[str]
    expected_tool: str = ""
    expected_routes: tuple[str, ...] = ("tool",)
    expected_arguments: dict[str, Any] | None = None


def _guide_context(*, page: int = 2, album_visible: bool = False) -> dict[str, Any]:
    return {
        "album": {
            "visible": album_visible,
            "page": 2,
            "page_count": 4,
            "can_next": album_visible,
            "can_previous": album_visible,
        },
        "task_guide": {
            "visible": True,
            "task_id": 1,
            "task_title": "无容器样品实验流程",
            "page_index": page,
            "page_count": 5,
            "can_next": page < 5,
            "can_previous": page > 1,
        },
    }


def _album_context(*, page: int = 2, page_count: int = 8) -> dict[str, Any]:
    return {
        "album": {
            "visible": True,
            "page": page,
            "page_count": page_count,
            "can_next": page < page_count,
            "can_previous": page > 1,
        },
        "task_guide": {"visible": False},
    }


def _closed_ui_context() -> dict[str, Any]:
    return {
        "album": {"visible": False},
        "task_guide": {"visible": False},
    }


def _cases() -> list[RoutingCase]:
    guide_tools = [
        "close_task_guide",
        "delegate_deepseek",
        "go_to_task_guide_page",
        "next_task_step",
        "open_album",
        "open_task_guide",
        "previous_task_step",
        "replay_current_task_step",
    ]
    album_tools = [
        "close_album",
        "delegate_deepseek",
        "get_album_state",
        "go_to_album_page",
        "next_album_page",
        "open_album",
        "open_task_guide",
        "previous_album_page",
    ]
    both_tools = sorted(set(guide_tools + album_tools))
    closed_ui_tools = ["delegate_deepseek", "open_album", "open_task_guide"]
    return [
        RoutingCase(
            "open work checklist alias",
            "打开工作清单",
            _closed_ui_context(),
            closed_ui_tools,
            "open_task_guide",
            expected_arguments={"task_id": 1},
        ),
        RoutingCase(
            "closed album direct page",
            "翻到相册第5页",
            _closed_ui_context(),
            closed_ui_tools,
            "open_album",
            expected_arguments={"page": 5, "refresh": True},
        ),
        RoutingCase(
            "guide previous page",
            "翻到上一页",
            _guide_context(),
            guide_tools,
            "previous_task_step",
        ),
        RoutingCase(
            "guide previous step",
            "回到前一步",
            _guide_context(),
            guide_tools,
            "previous_task_step",
        ),
        RoutingCase(
            "guide next page",
            "翻到下一页",
            _guide_context(),
            guide_tools,
            "next_task_step",
        ),
        RoutingCase(
            "guide completion",
            "这一步我做完了，接下来需要做什么",
            _guide_context(),
            guide_tools,
            "next_task_step",
        ),
        RoutingCase(
            "guide direct page",
            "翻到指导书第3页",
            _guide_context(),
            guide_tools,
            "go_to_task_guide_page",
            expected_arguments={"page": 3},
        ),
        RoutingCase(
            "guide Chinese ordinal page",
            "翻到第三页",
            _guide_context(),
            guide_tools,
            "go_to_task_guide_page",
            expected_arguments={"page": 3},
        ),
        RoutingCase(
            "album previous page",
            "翻到上一页",
            _album_context(),
            album_tools,
            "previous_album_page",
        ),
        RoutingCase(
            "album next page",
            "翻到下一页",
            _album_context(),
            album_tools,
            "next_album_page",
        ),
        RoutingCase(
            "album direct page",
            "翻到相册第5页",
            _album_context(),
            album_tools,
            "go_to_album_page",
            expected_arguments={"page": 5},
        ),
        RoutingCase(
            "album Chinese ordinal page",
            "翻到第三页",
            _album_context(),
            album_tools,
            "go_to_album_page",
            expected_arguments={"page": 3},
        ),
        RoutingCase(
            "both explicit guide",
            "指导书翻到上一页",
            _guide_context(album_visible=True),
            both_tools,
            "previous_task_step",
        ),
        RoutingCase(
            "both explicit album",
            "相册翻到上一页",
            _guide_context(album_visible=True),
            both_tools,
            "previous_album_page",
        ),
        RoutingCase(
            "both explicit album direct page",
            "翻到相册第5页",
            _guide_context(album_visible=True),
            both_tools,
            "go_to_album_page",
            expected_arguments={"page": 5},
        ),
        RoutingCase(
            "both ambiguous target",
            "翻到上一页",
            _guide_context(album_visible=True),
            both_tools,
            expected_routes=("clarify",),
        ),
        RoutingCase(
            "negated operation",
            "不要翻页",
            _guide_context(),
            guide_tools,
            expected_routes=("direct_answer", "clarify"),
        ),
        RoutingCase(
            "manual knowledge",
            "当前这一步具体应该怎么操作",
            _guide_context(),
            guide_tools,
            "delegate_deepseek",
            expected_routes=("delegate_deepseek",),
        ),
        RoutingCase(
            "current step explanation",
            "这一步在讲什么",
            _guide_context(),
            guide_tools,
            "delegate_deepseek",
            expected_routes=("delegate_deepseek",),
        ),
        RoutingCase(
            "direct greeting",
            "你好",
            _guide_context(),
            guide_tools,
            expected_routes=("direct_answer",),
        ),
    ]


async def _receive_json(websocket: Any, timeout_seconds: float) -> dict[str, Any]:
    raw = await asyncio.wait_for(websocket.recv(), timeout=timeout_seconds)
    value = json.loads(raw)
    if not isinstance(value, dict):
        raise RuntimeError("Gateway returned a non-object WebSocket message")
    return value


async def _run_case(
    websocket: Any,
    session_id: str,
    case: RoutingCase,
    timeout_seconds: float,
) -> tuple[bool, str]:
    request_id = f"routing-{uuid4().hex}"
    await websocket.send(
        json.dumps(
            make_envelope(
                "user_message",
                {
                    "text": case.text,
                    "context": case.context,
                    "allowed_tools": case.allowed_tools,
                },
                session_id=session_id,
                request_id=request_id,
            ),
            ensure_ascii=False,
        )
    )

    actual_call = ""
    actual_arguments: dict[str, Any] = {}
    final_payload: dict[str, Any] | None = None
    while final_payload is None:
        envelope = await _receive_json(websocket, timeout_seconds)
        if envelope.get("request_id") != request_id:
            continue
        message_type = envelope.get("type")
        if message_type == "run_error":
            payload = envelope.get("payload", {})
            return False, f"run_error={payload}"
        if message_type == "tool_call":
            payload = envelope.get("payload", {})
            actual_call = str(payload.get("name", ""))
            arguments = payload.get("arguments", {})
            actual_arguments = arguments if isinstance(arguments, dict) else {}
            tool_data: dict[str, Any] = {"acknowledged_tool": actual_call}
            if actual_call == "delegate_deepseek":
                tool_data["entries"] = [
                    {
                        "id": "live-current-step",
                        "title": "当前步骤",
                        "content": "当前步骤要求先确认设备状态，再按任务单执行。",
                    }
                ]
            await websocket.send(
                json.dumps(
                    make_envelope(
                        "tool_result",
                        {"ok": True, "data": tool_data, "error": None},
                        session_id=session_id,
                        request_id=request_id,
                        tool_call_id=str(envelope.get("tool_call_id", "")),
                    ),
                    ensure_ascii=False,
                )
            )
        elif message_type == "assistant_final":
            payload = envelope.get("payload", {})
            final_payload = payload if isinstance(payload, dict) else {}

    actual_route = str(final_payload.get("route", ""))
    actual_tool = str(final_payload.get("tool_name", ""))
    actual_answer = str(final_payload.get("answer", "")).strip().replace("\n", " ")[:160]
    if actual_route not in case.expected_routes:
        return (
            False,
            f"route expected={case.expected_routes} actual={actual_route!r} "
            f"tool={actual_tool or actual_call!r} answer={actual_answer!r}",
        )
    if case.expected_tool:
        selected = actual_tool or actual_call
        if selected != case.expected_tool:
            return (
                False,
                f"tool expected={case.expected_tool!r} actual={selected!r} "
                f"route={actual_route!r}",
            )
        if actual_call != case.expected_tool:
            return False, f"Gateway did not dispatch selected tool {case.expected_tool!r}"
        if (
            case.expected_arguments is not None
            and actual_arguments != case.expected_arguments
        ):
            return (
                False,
                f"arguments expected={case.expected_arguments} actual={actual_arguments}",
            )
    elif actual_call:
        return False, f"unexpected state/tool call {actual_call!r}"
    return True, f"route={actual_route} tool={actual_tool or '-'}"


async def _run(args: argparse.Namespace) -> int:
    async with websockets.connect(
        args.gateway,
        open_timeout=args.timeout,
        max_size=262_144,
    ) as websocket:
        await websocket.send(
            json.dumps(
                make_envelope(
                    "hello",
                    {"client_id": f"qwen-routing-headless-{uuid4().hex[:8]}"},
                )
            )
        )
        hello = await _receive_json(websocket, args.timeout)
        if hello.get("type") != "hello_ack":
            raise RuntimeError(f"Gateway handshake failed: {hello}")
        session_id = str(hello.get("session_id", ""))
        if not session_id:
            raise RuntimeError("Gateway did not assign a session ID")

        failures: list[str] = []
        cases = [
            case
            for case in _cases()
            if not args.case or args.case.lower() in case.name.lower()
        ]
        if not cases:
            raise RuntimeError(f"No routing case matched {args.case!r}")
        for case in cases:
            ok, detail = await _run_case(websocket, session_id, case, args.timeout)
            label = "PASS" if ok else "FAIL"
            print(f"[{label}] {case.name}: {detail}", flush=True)
            if not ok:
                failures.append(f"{case.name}: {detail}")

    print(
        f"{len(cases) - len(failures)}/{len(cases)} live Qwen routing cases passed.",
        flush=True,
    )
    if failures:
        print("Routing failures:", flush=True)
        for failure in failures:
            print(f"- {failure}", flush=True)
        return 1
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Run real-Qwen routing regression without opening Godot."
    )
    parser.add_argument(
        "--gateway",
        default="ws://127.0.0.1:7861/ws/godot",
        help="Agent Gateway WebSocket endpoint.",
    )
    parser.add_argument(
        "--timeout",
        type=float,
        default=60.0,
        help="Per-message timeout in seconds.",
    )
    parser.add_argument(
        "--case",
        default="",
        help="Run only cases whose names contain this text.",
    )
    return asyncio.run(_run(parser.parse_args()))


if __name__ == "__main__":
    raise SystemExit(main())
