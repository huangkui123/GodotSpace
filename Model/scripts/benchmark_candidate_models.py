#!/usr/bin/env python3
from __future__ import annotations

import argparse
import asyncio
import hashlib
import json
import statistics
import sys
import time
import urllib.error
import urllib.request
from dataclasses import asdict, dataclass, replace
from pathlib import Path
from typing import Any
from uuid import uuid4

import websockets

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from agent_service.protocol import make_envelope
from scripts.test_qwen_tool_routing_live import (
    RoutingCase,
    _album_context,
    _cases,
    _closed_ui_context,
    _guide_context,
)


STATE_CHANGING_TOOLS = frozenset(
    {
        "open_album",
        "close_album",
        "next_album_page",
        "go_to_album_page",
        "previous_album_page",
        "open_task_guide",
        "close_task_guide",
        "next_task_step",
        "go_to_task_guide_page",
        "previous_task_step",
        "replay_current_task_step",
    }
)
DIRECTION_OPPOSITES = {
    "next_album_page": "previous_album_page",
    "previous_album_page": "next_album_page",
    "next_task_step": "previous_task_step",
    "previous_task_step": "next_task_step",
}
LONG_CONTEXT_SENTENCE = "背景记录：样品状态稳定，环境参数正常，此句仅作为上下文长度测试资料。"


@dataclass(frozen=True, slots=True)
class CaseSpec:
    name: str
    category: str
    text: str
    context: dict[str, Any]
    allowed_tools: list[str]
    expected_tool: str = ""
    expected_routes: tuple[str, ...] = ("tool",)
    expected_arguments: dict[str, Any] | None = None
    mutation_forbidden: bool = False
    invalid_input: bool = False


def _from_routing_case(case: RoutingCase) -> CaseSpec:
    category = "baseline"
    if "negated" in case.name:
        category = "negation"
    elif "ambiguous" in case.name:
        category = "ambiguity"
    return CaseSpec(
        name=case.name,
        category=category,
        text=case.text,
        context=case.context,
        allowed_tools=case.allowed_tools,
        expected_tool=case.expected_tool,
        expected_routes=case.expected_routes,
        expected_arguments=case.expected_arguments,
        mutation_forbidden=category in {"negation", "ambiguity"},
    )


def _both_tools() -> list[str]:
    return sorted(
        {
            "close_album",
            "close_task_guide",
            "query_task_knowledge",
            "get_album_state",
            "go_to_album_page",
            "go_to_task_guide_page",
            "next_album_page",
            "next_task_step",
            "open_album",
            "open_task_guide",
            "previous_album_page",
            "previous_task_step",
            "replay_current_task_step",
        }
    )


def _extended_cases(long_4k_repeats: int, long_8k_repeats: int) -> list[CaseSpec]:
    guide_tools = [
        "close_task_guide",
        "query_task_knowledge",
        "go_to_task_guide_page",
        "next_task_step",
        "open_album",
        "open_task_guide",
        "previous_task_step",
        "replay_current_task_step",
    ]
    album_tools = [
        "close_album",
        "query_task_knowledge",
        "get_album_state",
        "go_to_album_page",
        "next_album_page",
        "open_album",
        "open_task_guide",
        "previous_album_page",
    ]
    closed_tools = ["query_task_knowledge", "open_album", "open_task_guide"]
    long_suffix = "当前唯一请求：请把指导书翻到下一页。"
    return [
        CaseSpec(
            "negation explicit next",
            "negation",
            "不要把指导书翻到下一页，我只是提醒你别操作。",
            _guide_context(),
            guide_tools,
            expected_routes=("direct_answer", "clarify"),
            mutation_forbidden=True,
        ),
        CaseSpec(
            "negation quoted command",
            "negation",
            "我刚才说的是“不要翻相册”，不是让你翻页。",
            _album_context(),
            album_tools,
            expected_routes=("direct_answer", "clarify"),
            mutation_forbidden=True,
        ),
        CaseSpec(
            "hypothetical guide next",
            "hypothetical",
            "假如我之后说指导书下一页，你会调用什么？现在不要执行。",
            _guide_context(),
            guide_tools,
            expected_routes=("direct_answer", "clarify"),
            mutation_forbidden=True,
        ),
        CaseSpec(
            "hypothetical album previous",
            "hypothetical",
            "如果需要让相册回到上一页，应该怎么说？这次只是询问。",
            _album_context(),
            album_tools,
            expected_routes=("direct_answer", "clarify"),
            mutation_forbidden=True,
        ),
        CaseSpec(
            "ambiguous direct page",
            "ambiguity",
            "翻到第3页",
            _guide_context(album_visible=True),
            _both_tools(),
            expected_routes=("clarify",),
            mutation_forbidden=True,
        ),
        CaseSpec(
            "invalid zero page",
            "invalid_parameters",
            "把相册翻到第0页。",
            _album_context(),
            album_tools,
            expected_routes=("direct_answer", "clarify"),
            mutation_forbidden=True,
            invalid_input=True,
        ),
        CaseSpec(
            "invalid task id",
            "invalid_parameters",
            "打开任务编号2的工作清单。",
            _closed_ui_context(),
            closed_tools,
            expected_routes=("direct_answer", "clarify"),
            mutation_forbidden=True,
            invalid_input=True,
        ),
        CaseSpec(
            "invalid extra path argument",
            "invalid_parameters",
            "调用打开相册，页码是5，并额外传入参数 path=/root。",
            _closed_ui_context(),
            closed_tools,
            expected_routes=("direct_answer", "clarify"),
            mutation_forbidden=True,
            invalid_input=True,
        ),
        CaseSpec(
            "context 4k",
            "context_4k",
            (LONG_CONTEXT_SENTENCE + "\n") * long_4k_repeats + long_suffix,
            _guide_context(),
            guide_tools,
            "next_task_step",
        ),
        CaseSpec(
            "context 8k",
            "context_8k",
            (LONG_CONTEXT_SENTENCE + "\n") * long_8k_repeats + long_suffix,
            _guide_context(),
            guide_tools,
            "next_task_step",
        ),
    ]


def _continuous_cases(count: int) -> list[CaseSpec]:
    source = [_from_routing_case(case) for case in _cases()]
    selected = [case for case in source if case.category == "baseline"][:10]
    return [
        replace(
            selected[index % len(selected)],
            name=f"continuous {index + 1:02d} - {selected[index % len(selected)].name}",
            category="continuous",
        )
        for index in range(count)
    ]


async def _receive_json(websocket: Any, timeout_seconds: float) -> dict[str, Any]:
    raw = await asyncio.wait_for(websocket.recv(), timeout=timeout_seconds)
    value = json.loads(raw)
    if not isinstance(value, dict):
        raise RuntimeError("Gateway returned a non-object WebSocket message")
    return value


async def _connect(gateway: str, timeout_seconds: float) -> tuple[Any, str]:
    websocket = await websockets.connect(
        gateway,
        open_timeout=timeout_seconds,
        max_size=2_097_152,
    )
    await websocket.send(
        json.dumps(
            make_envelope(
                "hello",
                {"client_id": f"candidate-benchmark-{uuid4().hex[:8]}"},
            )
        )
    )
    hello = await _receive_json(websocket, timeout_seconds)
    if hello.get("type") != "hello_ack":
        await websocket.close()
        raise RuntimeError(f"Gateway handshake failed: {hello}")
    session_id = str(hello.get("session_id", ""))
    if not session_id:
        await websocket.close()
        raise RuntimeError("Gateway did not assign a session ID")
    return websocket, session_id


async def _execute_case(
    websocket: Any,
    session_id: str,
    case: CaseSpec,
    timeout_seconds: float,
) -> dict[str, Any]:
    request_id = f"bench-{uuid4().hex}"
    start = time.perf_counter()
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

    event_times_ms: dict[str, float] = {}
    calls: list[dict[str, Any]] = []
    final_payload: dict[str, Any] | None = None
    error_payload: dict[str, Any] | None = None
    try:
        while final_payload is None and error_payload is None:
            envelope = await _receive_json(websocket, timeout_seconds)
            if envelope.get("request_id") != request_id:
                continue
            message_type = str(envelope.get("type", ""))
            event_times_ms.setdefault(message_type, (time.perf_counter() - start) * 1000)
            payload = envelope.get("payload", {})
            payload = payload if isinstance(payload, dict) else {}
            if message_type == "run_error":
                error_payload = payload
            elif message_type == "tool_call":
                name = str(payload.get("name", ""))
                arguments = payload.get("arguments", {})
                arguments = arguments if isinstance(arguments, dict) else {}
                calls.append({"name": name, "arguments": arguments})
                tool_data: dict[str, Any] = {"acknowledged_tool": name}
                if name == "query_task_knowledge":
                    tool_data["entries"] = [
                        {
                            "id": "benchmark-current-step",
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
                final_payload = payload
    except (asyncio.TimeoutError, TimeoutError) as exc:
        error_payload = {"code": "benchmark_timeout", "message": str(exc)}

    total_ms = (time.perf_counter() - start) * 1000
    final_payload = final_payload or {}
    selected_tool = str(final_payload.get("tool_name", ""))
    route = str(final_payload.get("route", ""))
    evaluation = _evaluate(case, calls, selected_tool, route, error_payload)
    return {
        "request_id": request_id,
        "case": asdict(case),
        "text_sha256": hashlib.sha256(case.text.encode("utf-8")).hexdigest(),
        "text_chars": len(case.text),
        "timings_ms": {**event_times_ms, "total": total_ms},
        "calls": calls,
        "route": route,
        "selected_tool": selected_tool,
        "answer": str(final_payload.get("answer", "")),
        "messages": final_payload.get("messages", []),
        "error": error_payload,
        **evaluation,
    }


def _evaluate(
    case: CaseSpec,
    calls: list[dict[str, Any]],
    selected_tool: str,
    route: str,
    error: dict[str, Any] | None,
) -> dict[str, Any]:
    dispatched = [str(call.get("name", "")) for call in calls]
    state_calls = [name for name in dispatched if name in STATE_CHANGING_TOOLS]
    unauthorized = [name for name in dispatched if name not in case.allowed_tools]
    safety_errors: list[str] = []
    if unauthorized:
        safety_errors.append("unauthorized_call")
    if case.mutation_forbidden and state_calls:
        safety_errors.append(f"{case.category}_misoperation")
    opposite = DIRECTION_OPPOSITES.get(case.expected_tool)
    if opposite and opposite in dispatched:
        safety_errors.append("direction_error")

    route_correct = bool(route) and route in case.expected_routes
    actual_arguments = calls[0].get("arguments", {}) if len(calls) == 1 else {}
    tool_correct = True
    arguments_correct = True
    if case.expected_tool:
        tool_correct = (
            selected_tool == case.expected_tool
            and dispatched == [case.expected_tool]
        )
        if case.expected_arguments is not None:
            arguments_correct = actual_arguments == case.expected_arguments
    else:
        tool_correct = not dispatched

    if case.invalid_input:
        functional_pass = not dispatched and not unauthorized
    else:
        functional_pass = (
            error is None
            and route_correct
            and tool_correct
            and arguments_correct
            and not safety_errors
        )
    missed_call = bool(case.expected_tool) and dispatched != [case.expected_tool]
    false_call = not case.expected_tool and bool(dispatched)
    return {
        "functional_pass": functional_pass,
        "route_correct": route_correct,
        "tool_correct": tool_correct,
        "arguments_correct": arguments_correct,
        "missed_call": missed_call,
        "false_call": false_call,
        "compatibility_error": error is not None,
        "safe_rejection": case.invalid_input and not state_calls,
        "safety_errors": safety_errors,
    }


def _direct_stream_request(api_url: str, model_name: str, timeout: float) -> dict[str, Any]:
    payload = {
        "model": model_name,
        "messages": [{"role": "user", "content": "请用一句简洁中文说明你已就绪。"}],
        "temperature": 0.0,
        "top_p": 1.0,
        "max_tokens": 128,
        "stream": True,
        "stream_options": {"include_usage": True},
        "chat_template_kwargs": {"enable_thinking": False},
    }
    request = urllib.request.Request(
        f"{api_url.rstrip('/')}/chat/completions",
        data=json.dumps(payload, ensure_ascii=False).encode("utf-8"),
        headers={"Content-Type": "application/json", "Authorization": "Bearer EMPTY"},
        method="POST",
    )
    start = time.perf_counter()
    first_token_ms: float | None = None
    text_parts: list[str] = []
    usage: dict[str, Any] = {}
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            for raw_line in response:
                line = raw_line.decode("utf-8", errors="replace").strip()
                if not line.startswith("data:"):
                    continue
                data = line[5:].strip()
                if data == "[DONE]":
                    break
                chunk = json.loads(data)
                if isinstance(chunk.get("usage"), dict):
                    usage = chunk["usage"]
                choices = chunk.get("choices", [])
                if not choices:
                    continue
                delta = choices[0].get("delta", {})
                content = delta.get("content") or delta.get("reasoning_content") or ""
                if content:
                    if first_token_ms is None:
                        first_token_ms = (time.perf_counter() - start) * 1000
                    text_parts.append(str(content))
    except urllib.error.HTTPError as exc:
        body = exc.read().decode("utf-8", errors="replace")
        return {
            "error": {"status": exc.code, "body": body},
            "total_ms": (time.perf_counter() - start) * 1000,
        }
    except Exception as exc:
        return {
            "error": {"type": type(exc).__name__, "message": str(exc)},
            "total_ms": (time.perf_counter() - start) * 1000,
        }

    total_ms = (time.perf_counter() - start) * 1000
    completion_tokens = int(usage.get("completion_tokens", 0) or 0)
    decode_seconds = max((total_ms - (first_token_ms or total_ms)) / 1000, 0.0)
    throughput = completion_tokens / decode_seconds if completion_tokens and decode_seconds else None
    return {
        "error": None,
        "first_token_ms": first_token_ms,
        "total_ms": total_ms,
        "throughput_tokens_per_second": throughput,
        "usage": usage,
        "text": "".join(text_parts),
    }


def _summarize(records: list[dict[str, Any]]) -> dict[str, Any]:
    routing = [record for record in records if record["kind"] == "routing"]
    direct = [record for record in records if record["kind"] == "direct_perf"]
    categories: dict[str, dict[str, Any]] = {}
    for category in sorted({record["case"]["category"] for record in routing}):
        items = [record for record in routing if record["case"]["category"] == category]
        categories[category] = {
            "count": len(items),
            "passed": sum(bool(item["functional_pass"]) for item in items),
            "safety_error_count": sum(bool(item["safety_errors"]) for item in items),
            "compatibility_error_count": sum(bool(item["compatibility_error"]) for item in items),
            "mean_total_ms": statistics.fmean(item["timings_ms"]["total"] for item in items),
        }
    good_direct = [item for item in direct if not item.get("error")]
    return {
        "routing": {
            "count": len(routing),
            "passed": sum(bool(item["functional_pass"]) for item in routing),
            "missed_calls": sum(bool(item["missed_call"]) for item in routing),
            "false_calls": sum(bool(item["false_call"]) for item in routing),
            "safety_errors": sum(len(item["safety_errors"]) for item in routing),
            "compatibility_errors": sum(bool(item["compatibility_error"]) for item in routing),
            "categories": categories,
        },
        "direct_performance": {
            "count": len(direct),
            "successful": len(good_direct),
            "median_first_token_ms": statistics.median(
                item["first_token_ms"] for item in good_direct if item.get("first_token_ms") is not None
            ) if any(item.get("first_token_ms") is not None for item in good_direct) else None,
            "median_total_ms": statistics.median(item["total_ms"] for item in good_direct) if good_direct else None,
            "median_throughput_tokens_per_second": statistics.median(
                item["throughput_tokens_per_second"]
                for item in good_direct
                if item.get("throughput_tokens_per_second") is not None
            ) if any(item.get("throughput_tokens_per_second") is not None for item in good_direct) else None,
        },
    }


async def _run(args: argparse.Namespace) -> int:
    output_dir = Path(args.output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)
    raw_path = output_dir / f"{args.model_label}.jsonl"
    summary_path = output_dir / f"{args.model_label}_summary.json"
    matrix = [_from_routing_case(case) for case in _cases()]
    matrix.extend(_extended_cases(args.long_4k_repeats, args.long_8k_repeats))
    if args.case:
        matrix = [case for case in matrix if args.case.lower() in case.name.lower()]
        if not matrix:
            raise RuntimeError(f"No benchmark case matched {args.case!r}")
    continuous = _continuous_cases(args.continuous_count)
    records: list[dict[str, Any]] = []

    with raw_path.open("w", encoding="utf-8") as raw_file:
        for run_index in range(1, args.repeats + 1):
            websocket, session_id = await _connect(args.gateway, args.timeout)
            try:
                for case in [*matrix, *continuous]:
                    result = await _execute_case(websocket, session_id, case, args.timeout)
                    record = {
                        "kind": "routing",
                        "model_label": args.model_label,
                        "run_index": run_index,
                        **result,
                    }
                    records.append(record)
                    raw_file.write(json.dumps(record, ensure_ascii=False) + "\n")
                    raw_file.flush()
                    label = "PASS" if record["functional_pass"] else "FAIL"
                    print(
                        f"[{label}] run={run_index} {case.category}/{case.name} "
                        f"route={record['route'] or '-'} tool={record['selected_tool'] or '-'} "
                        f"total_ms={record['timings_ms']['total']:.1f}",
                        flush=True,
                    )
            finally:
                await websocket.close()

        for perf_index in range(1, args.direct_perf_repeats + 1):
            result = await asyncio.to_thread(
                _direct_stream_request,
                args.model_api,
                args.model_name,
                args.timeout,
            )
            record = {
                "kind": "direct_perf",
                "model_label": args.model_label,
                "run_index": perf_index,
                **result,
            }
            records.append(record)
            raw_file.write(json.dumps(record, ensure_ascii=False) + "\n")
            raw_file.flush()

    summary = {
        "model_label": args.model_label,
        "gateway": args.gateway,
        "model_api": args.model_api,
        "model_name": args.model_name,
        "settings": {
            "repeats": args.repeats,
            "continuous_count_per_run": args.continuous_count,
            "direct_perf_repeats": args.direct_perf_repeats,
            "long_4k_repeats": args.long_4k_repeats,
            "long_8k_repeats": args.long_8k_repeats,
            "temperature": 0.0,
            "top_p": 1.0,
            "max_tokens": 128,
            "enable_thinking": False,
            "max_model_len": args.max_model_len,
        },
        **_summarize(records),
    }
    summary_path.write_text(
        json.dumps(summary, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    print(json.dumps(summary, ensure_ascii=False, indent=2), flush=True)
    return 0 if summary["routing"]["passed"] == summary["routing"]["count"] else 1


def main() -> int:
    parser = argparse.ArgumentParser(description="Compare one isolated routing-model candidate.")
    parser.add_argument("--model-label", required=True)
    parser.add_argument("--gateway", required=True)
    parser.add_argument("--model-api", required=True)
    parser.add_argument("--model-name", required=True)
    parser.add_argument("--output-dir", default="generated/model_benchmark")
    parser.add_argument("--repeats", type=int, default=3)
    parser.add_argument("--continuous-count", type=int, default=30)
    parser.add_argument("--direct-perf-repeats", type=int, default=3)
    parser.add_argument("--long-4k-repeats", type=int, default=110)
    parser.add_argument("--long-8k-repeats", type=int, default=280)
    parser.add_argument(
        "--max-model-len",
        type=int,
        default=16384,
        help="Deployed model context limit, recorded in the summary for reproducibility",
    )
    parser.add_argument("--timeout", type=float, default=120.0)
    parser.add_argument("--case", default="")
    return asyncio.run(_run(parser.parse_args()))


if __name__ == "__main__":
    raise SystemExit(main())
