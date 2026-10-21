#!/usr/bin/env python3
"""Exercise one OpenAI-compatible native tool call and its follow-up answer."""

from __future__ import annotations

import argparse
import json
import time
import urllib.request
from typing import Any


TOOLS = [
    {
        "type": "function",
        "function": {
            "name": "get_current_task_step",
            "description": "读取当前任务步骤。用户询问现在做到哪一步或这一步怎么做时调用。",
            "parameters": {"type": "object", "properties": {}, "additionalProperties": False},
        },
    },
    {
        "type": "function",
        "function": {
            "name": "open_album",
            "description": "打开相册界面。",
            "parameters": {"type": "object", "properties": {}, "additionalProperties": False},
        },
    },
]


def chat(endpoint: str, payload: dict[str, Any], timeout: float) -> tuple[dict[str, Any], float]:
    request = urllib.request.Request(
        f"{endpoint.rstrip('/')}/chat/completions",
        data=json.dumps(payload, ensure_ascii=False).encode("utf-8"),
        headers={"Content-Type": "application/json", "Authorization": "Bearer EMPTY"},
        method="POST",
    )
    started = time.perf_counter()
    with urllib.request.urlopen(request, timeout=timeout) as response:
        result = json.loads(response.read().decode("utf-8"))
    return result, (time.perf_counter() - started) * 1000.0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--endpoint", required=True)
    parser.add_argument("--model", required=True)
    parser.add_argument("--timeout", type=float, default=120.0)
    args = parser.parse_args()

    first_payload = {
        "model": args.model,
        "messages": [{"role": "user", "content": "请告诉我当前任务进行到哪一步。"}],
        "tools": TOOLS,
        "tool_choice": "auto",
        "temperature": 0.0,
        "max_tokens": 256,
    }
    first, first_ms = chat(args.endpoint, first_payload, args.timeout)
    message = first["choices"][0]["message"]
    calls = message.get("tool_calls") or []
    if len(calls) != 1 or calls[0].get("function", {}).get("name") != "get_current_task_step":
        print(json.dumps({"passed": False, "phase": "selection", "response": first}, ensure_ascii=False))
        return 1

    follow_messages = [*first_payload["messages"], message]
    follow_messages.append(
        {
            "role": "tool",
            "tool_call_id": calls[0]["id"],
            "name": "get_current_task_step",
            "content": json.dumps(
                {"step": 8, "instruction": "确保佩戴防静电手环与手套，断开连接器X01和X02。"},
                ensure_ascii=False,
            ),
        }
    )
    second_payload = {
        "model": args.model,
        "messages": follow_messages,
        "tools": TOOLS,
        "tool_choice": "auto",
        "temperature": 0.0,
        "max_tokens": 256,
    }
    second, second_ms = chat(args.endpoint, second_payload, args.timeout)
    final_message = second["choices"][0]["message"]
    answer = str(final_message.get("content") or "")
    passed = "8" in answer and "X01" in answer and "X02" in answer and not final_message.get("tool_calls")
    print(
        json.dumps(
            {
                "passed": passed,
                "selected_tool": calls[0]["function"]["name"],
                "arguments": calls[0]["function"].get("arguments"),
                "first_call_ms": first_ms,
                "follow_up_ms": second_ms,
                "answer": answer,
            },
            ensure_ascii=False,
            indent=2,
        )
    )
    return 0 if passed else 1


if __name__ == "__main__":
    raise SystemExit(main())
