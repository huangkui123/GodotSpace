#!/usr/bin/env python3
from __future__ import annotations

import argparse
import asyncio
import json
import math
import statistics
import subprocess
import sys
import time
from collections import Counter, defaultdict
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any
from urllib.parse import urlsplit, urlunsplit
from urllib.request import urlopen
from uuid import uuid4

import websockets

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from agent_service.protocol import make_envelope
from agent_service.tool_call_harness import (
    STATE_CHANGING_TOOLS,
    normalize_tool_arguments,
    tool_for_semantic_frame,
)


DEFAULT_SUITE = (
    Path(__file__).resolve().parents[1]
    / "agent_service"
    / "tests"
    / "fixtures"
    / "tool_call_cases.json"
)


@dataclass(frozen=True, slots=True)
class BenchmarkCase:
    case_id: str
    category: str
    text: str
    context: dict[str, Any]
    allowed_tools: list[str]
    expected_tool: str = ""
    expected_arguments: dict[str, Any] | None = None
    expected_route: str = ""
    expected_routes: tuple[str, ...] = ()
    safe_fallback_routes: tuple[str, ...] = ()
    mutation_forbidden: bool = False
    expected_answer_contains: tuple[str, ...] = ()
    forbidden_answer_contains: tuple[str, ...] = ()
    expected_suggested_tool: str = ""
    expected_suggested_arguments: dict[str, Any] | None = None
    follow_up_text: str = ""
    expected_follow_up_tool: str = ""
    expected_follow_up_arguments: dict[str, Any] | None = None


def load_suite(path: Path) -> list[BenchmarkCase]:
    raw = json.loads(path.read_text(encoding="utf-8"))
    contexts = raw.get("contexts", {})
    tool_profiles = raw.get("tool_profiles", {})
    cases: list[BenchmarkCase] = []
    seen: set[str] = set()
    for item in raw.get("cases", []):
        case_id = str(item.get("id", "")).strip()
        context_name = str(item.get("context", "")).strip()
        tool_name = str(item.get("tools", "")).strip()
        if not case_id or case_id in seen:
            raise ValueError(f"Missing or duplicate case id: {case_id!r}")
        if context_name not in contexts or tool_name not in tool_profiles:
            raise ValueError(f"Unknown context/tool profile in case {case_id!r}")
        expected_arguments = item.get("expected_arguments")
        if expected_arguments is not None and not isinstance(expected_arguments, dict):
            raise ValueError(f"expected_arguments must be an object in {case_id!r}")
        expected_suggested_arguments = item.get("expected_suggested_arguments")
        if expected_suggested_arguments is not None and not isinstance(
            expected_suggested_arguments, dict
        ):
            raise ValueError(
                f"expected_suggested_arguments must be an object in {case_id!r}"
            )
        expected_follow_up_arguments = item.get("expected_follow_up_arguments")
        if expected_follow_up_arguments is not None and not isinstance(
            expected_follow_up_arguments, dict
        ):
            raise ValueError(
                f"expected_follow_up_arguments must be an object in {case_id!r}"
            )
        for field_name in ("expected_answer_contains", "forbidden_answer_contains"):
            values = item.get(field_name, [])
            if not isinstance(values, list) or any(
                not isinstance(value, str) or not value for value in values
            ):
                raise ValueError(f"{field_name} must be an array of strings in {case_id!r}")
        seen.add(case_id)
        cases.append(
            BenchmarkCase(
                case_id=case_id,
                category=str(item.get("category", "uncategorized")),
                text=str(item.get("text", "")),
                context=dict(contexts[context_name]),
                allowed_tools=list(tool_profiles[tool_name]),
                expected_tool=str(item.get("expected_tool", "")),
                expected_arguments=(
                    dict(expected_arguments) if isinstance(expected_arguments, dict) else None
                ),
                expected_route=str(item.get("expected_route", "")),
                expected_routes=tuple(
                    str(route) for route in item.get("expected_routes", [])
                ),
                safe_fallback_routes=tuple(
                    str(route) for route in item.get("safe_fallback_routes", [])
                ),
                mutation_forbidden=item.get("mutation_forbidden") is True,
                expected_answer_contains=tuple(item.get("expected_answer_contains", [])),
                forbidden_answer_contains=tuple(item.get("forbidden_answer_contains", [])),
                expected_suggested_tool=str(
                    item.get("expected_suggested_tool", "")
                ),
                expected_suggested_arguments=(
                    dict(expected_suggested_arguments)
                    if isinstance(expected_suggested_arguments, dict)
                    else None
                ),
                follow_up_text=str(item.get("follow_up_text", "")),
                expected_follow_up_tool=str(
                    item.get("expected_follow_up_tool", "")
                ),
                expected_follow_up_arguments=(
                    dict(expected_follow_up_arguments)
                    if isinstance(expected_follow_up_arguments, dict)
                    else None
                ),
            )
        )
    if not cases:
        raise ValueError("Tool-call benchmark suite is empty")
    return cases


def evaluate_result(case: BenchmarkCase, result: dict[str, Any]) -> dict[str, Any]:
    calls = result.get("tool_calls", [])
    final = result.get("assistant_final", {})
    harness = final.get("tool_harness", {}) if isinstance(final, dict) else {}
    calls = calls if isinstance(calls, list) else []
    harness = harness if isinstance(harness, dict) else {}
    harness_trace = final.get("harness_trace", {}) if isinstance(final, dict) else {}
    harness_trace = harness_trace if isinstance(harness_trace, dict) else {}
    harness_stages = harness_trace.get("stages", [])
    harness_stages = (
        [stage for stage in harness_stages if isinstance(stage, dict)]
        if isinstance(harness_stages, list)
        else []
    )
    route = str(final.get("route", "")) if isinstance(final, dict) else ""
    answer = str(final.get("answer", "")) if isinstance(final, dict) else ""

    errors: list[str] = []
    degraded_safe_fallback = False
    strict_match = True
    if harness_trace.get("version") != 1:
        strict_match = False
        errors.append("missing or unsupported harness_trace version")
    if not any(stage.get("type") == "tool_call" for stage in harness_stages):
        strict_match = False
        errors.append("missing tool_call harness stage")
    if not str(harness.get("action", "")) or not str(harness.get("reason", "")):
        strict_match = False
        errors.append("missing tool_harness decision metadata")
    if case.expected_tool:
        fallback_routes = case.safe_fallback_routes
        if not calls and route in fallback_routes:
            degraded_safe_fallback = True
            strict_match = False
        elif len(calls) != 1:
            strict_match = False
            errors.append(f"expected one call to {case.expected_tool}, got {len(calls)}")
        elif str(calls[0].get("name", "")) != case.expected_tool:
            strict_match = False
            errors.append(
                f"expected tool {case.expected_tool}, got {calls[0].get('name', '')}"
            )
        elif (
            case.expected_arguments is not None
            and calls[0].get("arguments") != case.expected_arguments
        ):
            strict_match = False
            errors.append(
                f"expected arguments {case.expected_arguments}, "
                f"got {calls[0].get('arguments')}"
            )
    elif calls:
        strict_match = False
        errors.append(f"expected no tool call, got {[call.get('name') for call in calls]}")

    accepted_routes = case.expected_routes or (
        (case.expected_route,) if case.expected_route else ()
    )
    if accepted_routes and route not in accepted_routes:
        strict_match = False
        errors.append(f"expected route in {accepted_routes}, got {route}")

    suggested_tool = str(harness.get("suggested_tool", ""))
    suggested_arguments = harness.get("suggested_arguments", {})
    if (
        case.expected_suggested_tool
        and suggested_tool != case.expected_suggested_tool
    ):
        strict_match = False
        errors.append(
            f"expected suggested tool {case.expected_suggested_tool}, got {suggested_tool}"
        )
    if (
        case.expected_suggested_arguments is not None
        and suggested_arguments != case.expected_suggested_arguments
    ):
        strict_match = False
        errors.append(
            f"expected suggested arguments {case.expected_suggested_arguments}, "
            f"got {suggested_arguments}"
        )

    missing_answer_fragments = [
        fragment for fragment in case.expected_answer_contains if fragment not in answer
    ]
    if missing_answer_fragments:
        strict_match = False
        errors.append(f"answer missing required fragments: {missing_answer_fragments}")
    forbidden_answer_fragments = [
        fragment for fragment in case.forbidden_answer_contains if fragment in answer
    ]
    if forbidden_answer_fragments:
        strict_match = False
        errors.append(f"answer contains forbidden fragments: {forbidden_answer_fragments}")

    state_calls = [
        str(call.get("name", ""))
        for call in calls
        if str(call.get("name", "")) in STATE_CHANGING_TOOLS
    ]
    false_mutation = case.mutation_forbidden and bool(state_calls)
    if false_mutation:
        strict_match = False
        errors.append(f"forbidden state mutation: {state_calls}")

    unauthorized_calls = [
        str(call.get("name", ""))
        for call in calls
        if str(call.get("name", "")) not in case.allowed_tools
    ]
    if unauthorized_calls:
        strict_match = False
        errors.append(f"unauthorized calls: {unauthorized_calls}")

    follow_up = result.get("follow_up", {})
    follow_up = follow_up if isinstance(follow_up, dict) else {}
    follow_up_calls = follow_up.get("tool_calls", [])
    follow_up_calls = follow_up_calls if isinstance(follow_up_calls, list) else []
    follow_up_final = follow_up.get("assistant_final", {})
    follow_up_final = follow_up_final if isinstance(follow_up_final, dict) else {}
    if case.expected_follow_up_tool:
        if len(follow_up_calls) != 1:
            strict_match = False
            errors.append(
                f"expected follow-up call to {case.expected_follow_up_tool}, "
                f"got {len(follow_up_calls)}"
            )
        elif str(follow_up_calls[0].get("name", "")) != case.expected_follow_up_tool:
            strict_match = False
            errors.append(
                f"expected follow-up tool {case.expected_follow_up_tool}, "
                f"got {follow_up_calls[0].get('name', '')}"
            )
        elif (
            case.expected_follow_up_arguments is not None
            and follow_up_calls[0].get("arguments")
            != case.expected_follow_up_arguments
        ):
            strict_match = False
            errors.append(
                f"expected follow-up arguments {case.expected_follow_up_arguments}, "
                f"got {follow_up_calls[0].get('arguments')}"
            )

    proposed_tool = str(harness.get("proposed_tool", ""))
    proposed_arguments = harness.get("proposed_arguments", {})
    semantic_frame = harness.get("semantic_frame", {})
    semantic_frame = semantic_frame if isinstance(semantic_frame, dict) else {}
    semantic_tool = tool_for_semantic_frame(semantic_frame)
    semantic_valid = bool(semantic_tool)
    semantic_consistent = bool(semantic_valid and semantic_tool == proposed_tool)
    unsafe_semantic_classification = bool(
        case.mutation_forbidden
        and semantic_frame.get("request_mode") == "execute"
        and semantic_tool in STATE_CHANGING_TOOLS
    )
    action_entailment = harness.get("action_entailment", {})
    action_entailment = (
        action_entailment if isinstance(action_entailment, dict) else {}
    )
    model_attempts = int(harness.get("model_attempts", 0) or 0)
    normalized_proposal: dict[str, Any] = {}
    proposal_error = ""
    if proposed_tool and isinstance(proposed_arguments, dict):
        normalized_proposal, proposal_error = normalize_tool_arguments(
            proposed_tool,
            proposed_arguments,
        )
    raw_applicable = bool(case.expected_tool and model_attempts > 0)
    raw_exact = bool(
        raw_applicable
        and proposed_tool == case.expected_tool
        and not proposal_error
        and (
            case.expected_arguments is None
            or normalized_proposal == case.expected_arguments
        )
    )
    return {
        "passed": not errors,
        "strict_passed": strict_match and not errors,
        "errors": errors,
        "route": route,
        "answer": answer,
        "effective_tool": str(calls[0].get("name", "")) if len(calls) == 1 else "",
        "effective_arguments": calls[0].get("arguments", {}) if len(calls) == 1 else {},
        "false_mutation": false_mutation,
        "degraded_safe_fallback": degraded_safe_fallback,
        "unauthorized_calls": unauthorized_calls,
        "harness_action": str(harness.get("action", "")),
        "harness_reason": str(harness.get("reason", "")),
        "corrected": harness.get("corrected") is True,
        "model_attempts": model_attempts,
        "proposed_tool": proposed_tool,
        "proposed_arguments": proposed_arguments,
        "suggested_tool": suggested_tool,
        "suggested_arguments": suggested_arguments,
        "follow_up_route": str(follow_up_final.get("route", "")),
        "follow_up_tool": (
            str(follow_up_calls[0].get("name", ""))
            if len(follow_up_calls) == 1
            else ""
        ),
        "semantic_frame": semantic_frame,
        "semantic_tool": semantic_tool,
        "semantic_valid": semantic_valid,
        "semantic_consistent": semantic_consistent,
        "unsafe_semantic_classification": unsafe_semantic_classification,
        "action_entailment": action_entailment,
        "entailment_verdict": str(action_entailment.get("verdict", "")),
        "harness_trace_version": harness_trace.get("version"),
        "harness_stages": harness_stages,
        "semantic_verifier_attempts": int(
            harness.get("semantic_verifier_attempts", 0) or 0
        ),
        "raw_applicable": raw_applicable,
        "raw_exact": raw_exact,
    }


def summarize(records: list[dict[str, Any]]) -> dict[str, Any]:
    completed = [record for record in records if not record.get("transport_error")]
    latencies = sorted(
        float(record["latency_ms"])
        for record in completed
        if isinstance(record.get("latency_ms"), (int, float))
    )
    harness_stages = [
        stage
        for record in completed
        for stage in record.get("harness_stages", [])
        if isinstance(stage, dict)
    ]
    by_category: dict[str, Counter[str]] = defaultdict(Counter)
    reasons: Counter[str] = Counter()
    failures: Counter[str] = Counter()
    for record in records:
        category = str(record["category"])
        by_category[category]["total"] += 1
        if record.get("transport_error"):
            by_category[category]["runtime_errors"] += 1
            failures[f"transport:{record.get('transport_error')}"] += 1
            continue
        by_category[category]["completed"] += 1
        by_category[category]["passed"] += int(record.get("passed") is True)
        by_category[category]["strict_passed"] += int(
            record.get("strict_passed") is True
        )
        by_category[category]["raw_applicable"] += int(record.get("raw_applicable") is True)
        by_category[category]["raw_exact"] += int(record.get("raw_exact") is True)
        by_category[category]["degraded_safe_fallback"] += int(
            record.get("degraded_safe_fallback") is True
        )
        by_category[category]["semantic_valid"] += int(
            record.get("semantic_valid") is True
        )
        by_category[category]["semantic_consistent"] += int(
            record.get("semantic_consistent") is True
        )
        reason = str(record.get("harness_reason", ""))
        if reason:
            reasons[reason] += 1
        for error in record.get("errors", []):
            failures[str(error)] += 1
    raw_applicable = sum(record.get("raw_applicable") is True for record in completed)
    raw_exact = sum(record.get("raw_exact") is True for record in completed)
    effective_passed = sum(record.get("passed") is True for record in records)
    strict_passed = sum(record.get("strict_passed") is True for record in records)
    return {
        "requests": len(records),
        "completed": len(completed),
        "runtime_errors": len(records) - len(completed),
        "effective_passed": effective_passed,
        "effective_pass_rate": _rate(effective_passed, len(records)),
        "strict_passed": strict_passed,
        "strict_pass_rate": _rate(strict_passed, len(records)),
        "false_mutations": sum(record.get("false_mutation") is True for record in records),
        "unauthorized_calls": sum(bool(record.get("unauthorized_calls")) for record in records),
        "corrected": sum(record.get("corrected") is True for record in completed),
        "degraded_safe_fallbacks": sum(
            record.get("degraded_safe_fallback") is True for record in completed
        ),
        "harness_fallbacks": sum(
            stage.get("fallback_used") is True for stage in harness_stages
        ),
        "harness_outcomes": dict(
            Counter(
                f"{stage.get('type', 'unknown')}:{stage.get('outcome', 'unknown')}"
                for stage in harness_stages
            )
        ),
        "model_attempted": sum(int(record.get("model_attempts", 0)) > 0 for record in completed),
        "raw_applicable": raw_applicable,
        "raw_exact": raw_exact,
        "raw_exact_rate": _rate(raw_exact, raw_applicable),
        "semantic_valid": sum(record.get("semantic_valid") is True for record in completed),
        "semantic_consistent": sum(
            record.get("semantic_consistent") is True for record in completed
        ),
        "unsafe_semantic_classifications": sum(
            record.get("unsafe_semantic_classification") is True for record in completed
        ),
        "semantic_verifier_attempted": sum(
            int(record.get("semantic_verifier_attempts", 0)) > 0
            for record in completed
        ),
        "entailment_verdicts": dict(
            Counter(
                str(record.get("entailment_verdict"))
                for record in completed
                if record.get("entailment_verdict")
            )
        ),
        "latency_ms": {
            "mean": round(statistics.fmean(latencies), 1) if latencies else None,
            "p50": _percentile(latencies, 0.50),
            "p95": _percentile(latencies, 0.95),
        },
        "by_category": {
            category: {
                **dict(counts),
                "effective_pass_rate": _rate(counts["passed"], counts["total"]),
                "strict_pass_rate": _rate(
                    counts["strict_passed"], counts["total"]
                ),
                "raw_exact_rate": _rate(counts["raw_exact"], counts["raw_applicable"]),
                "semantic_consistency_rate": _rate(
                    counts["semantic_consistent"], counts["semantic_valid"]
                ),
            }
            for category, counts in sorted(by_category.items())
        },
        "harness_reasons": dict(reasons.most_common()),
        "failure_reasons": dict(failures.most_common()),
    }


async def _receive_json(websocket: Any, timeout_seconds: float) -> dict[str, Any]:
    raw = await asyncio.wait_for(websocket.recv(), timeout=timeout_seconds)
    value = json.loads(raw)
    if not isinstance(value, dict):
        raise RuntimeError("Gateway returned a non-object WebSocket message")
    return value


async def _run_case(
    websocket: Any,
    session_id: str,
    case: BenchmarkCase,
    timeout_seconds: float,
) -> dict[str, Any]:
    started = time.perf_counter()
    conversation_id = f"benchmark-{case.case_id}-{uuid4().hex[:8]}"

    async def exchange(text: str) -> dict[str, Any]:
        request_id = f"tool-benchmark-{uuid4().hex}"
        await websocket.send(
            json.dumps(
                make_envelope(
                    "user_message",
                    {
                        "text": text,
                        "context": case.context,
                        "allowed_tools": case.allowed_tools,
                        "conversation_id": conversation_id,
                    },
                    session_id=session_id,
                    request_id=request_id,
                ),
                ensure_ascii=False,
            )
        )
        calls: list[dict[str, Any]] = []
        final: dict[str, Any] = {}
        while not final:
            envelope = await _receive_json(websocket, timeout_seconds)
            if envelope.get("request_id") != request_id:
                continue
            message_type = envelope.get("type")
            payload = envelope.get("payload", {})
            if message_type == "run_error":
                raise RuntimeError(f"gateway run_error: {payload}")
            if message_type == "tool_call":
                arguments = payload.get("arguments", {}) if isinstance(payload, dict) else {}
                call = {
                    "name": str(payload.get("name", "")) if isinstance(payload, dict) else "",
                    "arguments": arguments if isinstance(arguments, dict) else {},
                }
                calls.append(call)
                tool_data: dict[str, Any] = {"acknowledged_tool": call["name"]}
                if call["name"] == "get_current_task_step":
                    guide = case.context.get("task_guide", {})
                    guide = guide if isinstance(guide, dict) else {}
                    tool_data.update(
                        {
                            "task_title": guide.get("task_title", ""),
                            "page_index": guide.get("page_index", 0),
                            "page_count": guide.get("page_count", 0),
                            "current_step": guide.get("current_step", {}),
                        }
                    )
                elif call["name"] == "query_task_knowledge":
                    tool_data["entries"] = [
                        {
                            "id": "benchmark-current-step",
                            "title": "当前步骤与操作参数",
                            "content": (
                                "当前步骤要求先确认设备状态，再按任务单执行。"
                                "六颗M6螺钉的目标力矩为2.5N·m。"
                            ),
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
                final = payload if isinstance(payload, dict) else {}
        return {"tool_calls": calls, "assistant_final": final}

    result = {
        **(await exchange(case.text)),
        "latency_ms": round((time.perf_counter() - started) * 1000, 1),
    }
    if case.follow_up_text:
        result["follow_up"] = await exchange(case.follow_up_text)
        result["latency_ms"] = round((time.perf_counter() - started) * 1000, 1)
    return result


async def run_benchmark(args: argparse.Namespace) -> tuple[list[dict[str, Any]], dict[str, Any]]:
    cases = load_suite(args.suite)
    if args.category:
        cases = [case for case in cases if case.category == args.category]
    if args.case:
        query = args.case.lower()
        cases = [case for case in cases if query in case.case_id.lower()]
    if not cases:
        raise ValueError("No benchmark cases matched the selected filters")

    records: list[dict[str, Any]] = []
    async with websockets.connect(args.gateway, open_timeout=args.timeout, max_size=524_288) as websocket:
        await websocket.send(
            json.dumps(
                make_envelope("hello", {"client_id": f"tool-harness-{uuid4().hex[:8]}"})
            )
        )
        hello = await _receive_json(websocket, args.timeout)
        if hello.get("type") != "hello_ack" or not hello.get("session_id"):
            raise RuntimeError(f"Gateway handshake failed: {hello}")
        session_id = str(hello["session_id"])

        for repeat in range(1, args.repeats + 1):
            for case in cases:
                base = {
                    "case_id": case.case_id,
                    "category": case.category,
                    "repeat": repeat,
                    "text": case.text,
                    "context": case.context,
                    "allowed_tools": case.allowed_tools,
                    "expected_tool": case.expected_tool,
                    "expected_arguments": case.expected_arguments,
                    "expected_route": case.expected_route,
                    "expected_routes": list(case.expected_routes),
                    "safe_fallback_routes": list(case.safe_fallback_routes),
                    "mutation_forbidden": case.mutation_forbidden,
                    "expected_answer_contains": list(case.expected_answer_contains),
                    "forbidden_answer_contains": list(case.forbidden_answer_contains),
                    "expected_suggested_tool": case.expected_suggested_tool,
                    "expected_suggested_arguments": case.expected_suggested_arguments,
                    "follow_up_text": case.follow_up_text,
                    "expected_follow_up_tool": case.expected_follow_up_tool,
                    "expected_follow_up_arguments": case.expected_follow_up_arguments,
                }
                try:
                    result = await _run_case(websocket, session_id, case, args.timeout)
                    evaluation = evaluate_result(case, result)
                    record = {**base, **result, **evaluation}
                except Exception as exc:
                    record = {
                        **base,
                        "passed": False,
                        "errors": [str(exc)],
                        "transport_error": type(exc).__name__,
                    }
                records.append(record)
                label = (
                    "PASS"
                    if record.get("strict_passed")
                    else "DEGRADED"
                    if record.get("passed")
                    else "FAIL"
                )
                proposed = record.get("proposed_tool") or "-"
                effective = record.get("effective_tool") or "-"
                reason = record.get("harness_reason") or record.get("transport_error") or "-"
                print(
                    f"[{label}] r{repeat} {case.case_id}: "
                    f"proposed={proposed} effective={effective} reason={reason}",
                    flush=True,
                )
    return records, summarize(records)


def _rate(numerator: int, denominator: int) -> float | None:
    return round(numerator / denominator, 4) if denominator else None


def _percentile(values: list[float], fraction: float) -> float | None:
    if not values:
        return None
    index = max(0, math.ceil(len(values) * fraction) - 1)
    return round(values[index], 1)


def _write_report(output: Path, records: list[dict[str, Any]], summary: dict[str, Any]) -> None:
    output.parent.mkdir(parents=True, exist_ok=True)
    with output.open("w", encoding="utf-8") as handle:
        for record in records:
            handle.write(json.dumps(record, ensure_ascii=False) + "\n")
    summary_path = output.with_name(f"{output.stem}.summary.json")
    summary_path.write_text(
        json.dumps(summary, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    print(f"Detailed JSONL: {output}")
    print(f"Summary JSON:  {summary_path}")


def _run_metadata(args: argparse.Namespace) -> dict[str, Any]:
    gateway_parts = urlsplit(args.gateway)
    readyz_scheme = "https" if gateway_parts.scheme == "wss" else "http"
    readyz_url = urlunsplit((readyz_scheme, gateway_parts.netloc, "/readyz", "", ""))
    gateway_health: dict[str, Any] = {}
    try:
        with urlopen(readyz_url, timeout=min(args.timeout, 5.0)) as response:
            value = json.loads(response.read().decode("utf-8"))
        if isinstance(value, dict):
            gateway_health = value
    except Exception as exc:
        gateway_health = {"metadata_error": f"{type(exc).__name__}: {exc}"}

    def git_output(*command: str) -> str:
        result = subprocess.run(
            ["git", *command],
            check=False,
            capture_output=True,
            text=True,
        )
        return result.stdout.strip() if result.returncode == 0 else ""

    return {
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "gateway": args.gateway,
        "gateway_health": gateway_health,
        "suite": str(args.suite.resolve()),
        "repeats": args.repeats,
        "category_filter": args.category,
        "case_filter": args.case,
        "git_head": git_output("rev-parse", "HEAD"),
        "git_dirty": bool(git_output("status", "--porcelain")),
    }


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Measure raw Qwen tool selection and harness-protected dispatch."
    )
    parser.add_argument("--gateway", default="ws://127.0.0.1:7861/ws/godot")
    parser.add_argument("--suite", type=Path, default=DEFAULT_SUITE)
    parser.add_argument("--repeats", type=int, default=3)
    parser.add_argument("--timeout", type=float, default=60.0)
    parser.add_argument("--category", default="")
    parser.add_argument("--case", default="")
    parser.add_argument(
        "--output",
        type=Path,
        default=Path("generated/tool_call_benchmark.jsonl"),
    )
    args = parser.parse_args()
    if args.repeats < 1:
        parser.error("--repeats must be at least 1")
    records, summary = asyncio.run(run_benchmark(args))
    summary["run"] = _run_metadata(args)
    _write_report(args.output, records, summary)
    print(json.dumps(summary, ensure_ascii=False, indent=2))
    return 0 if (
        summary["completed"] == summary["requests"]
        and summary["strict_passed"] == summary["requests"]
        and summary["false_mutations"] == 0
        and summary["unauthorized_calls"] == 0
    ) else 1


if __name__ == "__main__":
    raise SystemExit(main())
