#!/usr/bin/env python3
"""Evaluate the evidence-gated knowledge harness with the fixed QA suite."""

from __future__ import annotations

import argparse
import json
import statistics
import time
import urllib.request
from pathlib import Path
from typing import Any

from benchmark_local_knowledge_qa import evaluate_answer, load_suite, select_context


def post_json(url: str, payload: dict[str, Any], timeout: float) -> tuple[dict[str, Any], float]:
    request = urllib.request.Request(
        url,
        data=json.dumps(payload, ensure_ascii=False).encode("utf-8"),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    started = time.perf_counter()
    with urllib.request.urlopen(request, timeout=timeout) as response:
        result = json.loads(response.read().decode("utf-8"))
    return result, (time.perf_counter() - started) * 1000.0


def percentile(values: list[float], fraction: float) -> float | None:
    if not values:
        return None
    ordered = sorted(values)
    index = max(0, min(len(ordered) - 1, int((len(ordered) - 1) * fraction + 0.999999)))
    return ordered[index]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--suite", default="agent_service/tests/fixtures/knowledge_qa_cases.json")
    parser.add_argument("--endpoint", default="http://127.0.0.1:7866/v1/knowledge/answer")
    parser.add_argument("--mode", choices=("oracle", "retrieval", "both"), default="both")
    parser.add_argument("--repeats", type=int, default=3)
    parser.add_argument("--timeout", type=float, default=60.0)
    parser.add_argument("--output", default="generated/knowledge_harness/results.jsonl")
    args = parser.parse_args()

    suite = load_suite(Path(args.suite))
    modes = ("oracle", "retrieval") if args.mode == "both" else (args.mode,)
    output = Path(args.output)
    output.parent.mkdir(parents=True, exist_ok=True)
    records: list[dict[str, Any]] = []
    with output.open("w", encoding="utf-8") as raw_file:
        for repeat in range(1, args.repeats + 1):
            for mode in modes:
                for case in suite["cases"]:
                    scoring_context = select_context(suite, case, mode)
                    entries = []
                    for entry in case.get("runtime_context", []):
                        value = dict(entry)
                        value.pop("source", None)
                        entries.append(value)
                    corpus_ids = (
                        [str(item) for item in case.get("oracle_entry_ids", [])]
                        if mode == "oracle"
                        else None
                    )
                    payload: dict[str, Any] = {
                        "question": case["question"],
                        "runtime_entries": entries,
                    }
                    if corpus_ids is not None:
                        payload["corpus_entry_ids"] = corpus_ids
                    try:
                        result, latency_ms = post_json(
                            args.endpoint,
                            payload,
                            args.timeout,
                        )
                        evaluation = evaluate_answer(case, str(result["answer"]), scoring_context)
                        error = None
                    except Exception as exc:
                        result = {}
                        latency_ms = 0.0
                        evaluation = {}
                        error = f"{type(exc).__name__}: {exc}"
                    record = {
                        "case_id": case["id"],
                        "category": case["category"],
                        "mode": mode,
                        "repeat": repeat,
                        "answer": result.get("answer", ""),
                        "decision": result.get("decision", "error"),
                        "reason": result.get("reason", ""),
                        "retrieved_ids": result.get("retrieved_ids", []),
                        "model_attempts": result.get("model_attempts", 0),
                        "harness_trace": result.get("harness_trace", {}),
                        "latency_ms": latency_ms,
                        "error": error,
                        "evaluation": evaluation,
                    }
                    records.append(record)
                    raw_file.write(json.dumps(record, ensure_ascii=False) + "\n")
                    raw_file.flush()
                    label = "PASS" if evaluation.get("hard_pass") else "FAIL"
                    print(
                        f"[{label}] {repeat=} {mode=} {case['id']} "
                        f"decision={record['decision']} reason={record['reason']}",
                        flush=True,
                    )

    completed = [record for record in records if record["error"] is None]
    latencies = [float(record["latency_ms"]) for record in completed]
    stages = [
        stage
        for record in completed
        for stage in record.get("harness_trace", {}).get("stages", [])
        if isinstance(stage, dict)
    ]
    summary = {
        "requests": len(records),
        "completed": len(completed),
        "hard_passed": sum(bool(record["evaluation"].get("hard_pass")) for record in completed),
        "full_passed": sum(bool(record["evaluation"].get("pass")) for record in completed),
        "safety_failures": sum(
            bool(record["evaluation"].get("safety_failure")) for record in completed
        ),
        "model_calls": sum(int(record["model_attempts"]) for record in completed),
        "abstentions": sum(record["decision"] == "abstain" for record in completed),
        "harness_fallbacks": sum(stage.get("fallback_used") is True for stage in stages),
        "harness_outcomes": {
            outcome: sum(stage.get("outcome") == outcome for stage in stages)
            for outcome in sorted(
                {
                    str(stage.get("outcome"))
                    for stage in stages
                    if stage.get("outcome")
                }
            )
        },
        "p50_latency_ms": statistics.median(latencies) if latencies else None,
        "p95_latency_ms": percentile(latencies, 0.95),
    }
    summary_path = output.with_name(f"{output.stem}_summary.json")
    summary_path.write_text(json.dumps(summary, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(summary, ensure_ascii=False, indent=2))
    return 0 if len(completed) == len(records) else 1


if __name__ == "__main__":
    raise SystemExit(main())
