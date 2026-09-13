#!/usr/bin/env python3
"""Benchmark the deployed Qwen model as a local knowledge-answering backend.

The benchmark deliberately separates two questions:

* ``oracle``: can the model answer when the correct evidence is supplied?
* ``retrieval``: can it answer with evidence selected by the current Godot-style
  lexical retriever?

Only Python's standard library is required.  The script writes one JSONL record
per request and a machine-readable summary next to it.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import statistics
import time
import urllib.error
import urllib.request
from collections import defaultdict
from dataclasses import dataclass
from pathlib import Path
from typing import Any


DOMAIN_KEYWORDS = (
    "氧气", "分压", "舱门", "密封", "告警", "复核", "上报", "阀门", "传感器", "环境",
    "设备", "手册", "步骤", "任务", "专家", "航天员", "样品盒", "无容器", "工具", "手环",
    "连接器", "螺钉", "力矩", "断电", "口令", "确认", "复述", "风险", "安全",
)
SEPARATORS = ("，", "。", "？", "！", "、", ",", ".", "?", "!", ":", "：", ";", "；", " ", "\n", "\t", "（", "）", "(", ")")
REFUSAL_MARKERS = (
    "资料未提供", "资料中没有", "现有资料没有", "依据不足", "无法确认", "不能确认", "未给出",
    "未提供", "未命中", "无法给出", "请专家席确认", "请求专家席确认", "需要专家席确认",
    "查阅对应手册", "查看任务手册", "请确认", "不能直接",
)
MARKDOWN_PATTERNS = (r"```", r"^\s*#{1,6}\s", r"\*\*", r"^\s*[-*+]\s+")


@dataclass(frozen=True, slots=True)
class RunConfig:
    endpoint: str
    model: str
    timeout_seconds: float
    temperature: float
    max_tokens: int
    prompt_context_chars: int
    api_key: str


def load_suite(path: Path) -> dict[str, Any]:
    value = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(value, dict) or not isinstance(value.get("cases"), list):
        raise ValueError("The suite root must be an object containing a cases array")
    return value


def normalize_text(value: str) -> str:
    text = value.lower().replace("．", ".").replace("·", "").replace("•", "")
    text = text.replace("牛顿米", "牛米").replace("n·m", "nm").replace("n.m", "nm")
    return re.sub(r"[\s，。！？、,!?：:；;（）()\[\]【】'\"`_*#-]+", "", text)


def extract_terms(text: str) -> list[str]:
    normalized = text.lower()
    for separator in SEPARATORS:
        normalized = normalized.replace(separator, " ")
    terms: list[str] = []
    for raw in normalized.split(" "):
        term = raw.strip()
        if len(term) >= 2 and term not in terms:
            terms.append(term)
    for keyword in DOMAIN_KEYWORDS:
        if keyword in text and keyword not in terms:
            terms.append(keyword)
    return terms


def score_entry(entry: dict[str, Any], query: str) -> float:
    haystack = " ".join(
        [
            str(entry.get("title", "")),
            str(entry.get("source", "")),
            " ".join(str(item) for item in entry.get("tags", [])),
            str(entry.get("content", "")),
        ]
    ).lower()
    normalized_query = query.lower()
    score = 4.0 if normalized_query in haystack else 0.0
    for term in extract_terms(query):
        if term in haystack:
            score += 2.0 if term in str(entry.get("title", "")).lower() else 1.0
    for keyword in DOMAIN_KEYWORDS:
        if keyword in query and keyword in haystack:
            score += 2.0
    if "当前" in str(entry.get("source", "")):
        score += 0.75
    return score


def retrieve_like_current_godot(
    query: str,
    corpus: list[dict[str, Any]],
    limit: int,
) -> list[dict[str, Any]]:
    """Mirror llm_knowledge_base.gd, including its zero-hit first-entry fallback."""
    scored = [(score_entry(entry, query), index, entry) for index, entry in enumerate(corpus)]
    hits = [item for item in scored if item[0] > 0.0]
    hits.sort(key=lambda item: (-item[0], item[1]))
    results = [dict(item[2]) for item in hits[:limit]]
    if not results and corpus:
        results.append(dict(corpus[0]))
    return results


def select_context(
    suite: dict[str, Any],
    case: dict[str, Any],
    mode: str,
) -> list[dict[str, Any]]:
    runtime = [dict(item) for item in case.get("runtime_context", [])]
    corpus = [dict(item) for item in suite.get("corpus", [])]
    if mode == "oracle":
        wanted = set(str(item) for item in case.get("oracle_entry_ids", []))
        return runtime + [entry for entry in corpus if str(entry.get("id", "")) in wanted]
    if mode == "retrieval":
        limit = int(suite.get("max_context_entries", 5))
        return runtime + retrieve_like_current_godot(str(case["question"]), corpus, limit)
    raise ValueError(f"Unsupported mode: {mode}")


def truncate_text(text: str, limit: int) -> str:
    clean = text.strip()
    if limit <= 0:
        return ""
    if len(clean) <= limit:
        return clean
    if limit == 1:
        return "…"
    return clean[: limit - 1].strip() + "…"


def model_file_stem(model: str) -> str:
    normalized = re.sub(r"[^a-z0-9]+", "_", model.lower()).strip("_")
    return normalized or "model"


def format_context(entries: list[dict[str, Any]], character_limit: int) -> str:
    if not entries:
        return "暂无命中的本地知识条目。"
    chunks = []
    for index, entry in enumerate(entries, start=1):
        chunks.append(
            f"{index}. 来源：{entry.get('source', '知识库')}；"
            f"标题：{entry.get('title', '未命名条目')}\n{entry.get('content', '')}"
        )
    return truncate_text("\n\n".join(chunks), character_limit)


def build_request(
    suite: dict[str, Any],
    case: dict[str, Any],
    entries: list[dict[str, Any]],
    config: RunConfig,
) -> dict[str, Any]:
    systems = suite.get("system_messages", [])
    if len(systems) != 2:
        raise ValueError("The suite must contain exactly two system_messages")
    context = format_context(entries, config.prompt_context_chars)
    return {
        "model": config.model,
        "temperature": config.temperature,
        "max_tokens": config.max_tokens,
        "stream": False,
        "messages": [
            {"role": "system", "content": str(systems[0])},
            {"role": "system", "content": str(systems[1])},
            {
                "role": "user",
                "content": (
                    f"可用知识：\n{context}\n\n近期对话：\n暂无近期对话。\n\n"
                    f"航天员/专家语音问题：{case['question']}"
                ),
            },
        ],
    }


def call_chat_completions(config: RunConfig, payload: dict[str, Any]) -> tuple[str, dict[str, Any], float]:
    endpoint = config.endpoint.rstrip("/")
    url = endpoint if endpoint.endswith("/chat/completions") else f"{endpoint}/chat/completions"
    request = urllib.request.Request(
        url,
        data=json.dumps(payload, ensure_ascii=False).encode("utf-8"),
        headers={"Content-Type": "application/json", "Authorization": f"Bearer {config.api_key}"},
        method="POST",
    )
    start = time.perf_counter()
    with urllib.request.urlopen(request, timeout=config.timeout_seconds) as response:
        raw = response.read().decode("utf-8")
    elapsed_ms = (time.perf_counter() - start) * 1000.0
    parsed = json.loads(raw)
    choices = parsed.get("choices", [])
    if not choices:
        raise RuntimeError("The model response contained no choices")
    answer = str(choices[0].get("message", {}).get("content", "")).strip()
    if not answer:
        raise RuntimeError("The model returned an empty answer")
    return answer, parsed.get("usage", {}), elapsed_ms


def _contains_any(normalized_answer: str, alternatives: list[str]) -> bool:
    return any(normalize_text(item) in normalized_answer for item in alternatives)


def _contains_forbidden(normalized_answer: str, forbidden: str) -> bool:
    normalized_forbidden = normalize_text(forbidden)
    if not normalized_forbidden:
        return False
    # A plain substring check incorrectly treats 2.5Nm as 5Nm.  Numeric
    # prohibitions must not be embedded in a larger decimal/number token.
    if normalized_forbidden[0].isdigit():
        pattern = rf"(?<![0-9.]){re.escape(normalized_forbidden)}(?![0-9.])"
        return re.search(pattern, normalized_answer) is not None
    return normalized_forbidden in normalized_answer


def evaluate_answer(case: dict[str, Any], answer: str, context: list[dict[str, Any]]) -> dict[str, Any]:
    rubric = case.get("rubric", {})
    normalized = normalize_text(answer)
    missing_groups: list[list[str]] = []
    for group in rubric.get("required_any", []):
        alternatives = [str(item) for item in group]
        if not _contains_any(normalized, alternatives):
            missing_groups.append(alternatives)

    forbidden_hits = [
        str(item) for item in rubric.get("forbidden", []) if _contains_forbidden(normalized, str(item))
    ]
    forbidden_regex_hits = [
        str(pattern)
        for pattern in rubric.get("forbidden_regex", [])
        if re.search(str(pattern), answer, re.IGNORECASE)
    ]
    refusal_ok = True
    if bool(rubric.get("require_refusal", False)):
        refusal_ok = _contains_any(normalized, list(REFUSAL_MARKERS))

    citation_ok = True
    if bool(rubric.get("require_citation", True)):
        accepted = [str(item) for item in rubric.get("citation_any", [])]
        if not accepted:
            for entry in context:
                accepted.extend([str(entry.get("title", "")), str(entry.get("source", ""))])
        accepted = [item for item in accepted if item.strip()]
        citation_ok = bool(accepted) and _contains_any(normalized, accepted)

    markdown_hits = [pattern for pattern in MARKDOWN_PATTERNS if re.search(pattern, answer, re.MULTILINE)]
    max_chars = int(rubric.get("max_chars", 800))
    concise_ok = len(answer) <= max_chars
    hard_pass = not missing_groups and not forbidden_hits and not forbidden_regex_hits and refusal_ok
    format_pass = citation_ok and not markdown_hits and concise_ok
    critical = bool(rubric.get("critical", False))
    safety_failure = critical and not hard_pass
    return {
        "pass": hard_pass and format_pass,
        "hard_pass": hard_pass,
        "format_pass": format_pass,
        "safety_failure": safety_failure,
        "missing_required_groups": missing_groups,
        "forbidden_hits": forbidden_hits,
        "forbidden_regex_hits": forbidden_regex_hits,
        "refusal_ok": refusal_ok,
        "citation_ok": citation_ok,
        "markdown_hits": markdown_hits,
        "concise_ok": concise_ok,
        "answer_chars": len(answer),
    }


def summarize(records: list[dict[str, Any]]) -> dict[str, Any]:
    completed = [record for record in records if record.get("error") is None]
    by_mode: dict[str, list[dict[str, Any]]] = defaultdict(list)
    by_category: dict[str, list[dict[str, Any]]] = defaultdict(list)
    for record in records:
        by_mode[str(record["mode"])].append(record)
        by_category[f"{record['mode']}/{record['category']}"].append(record)

    def group_summary(items: list[dict[str, Any]]) -> dict[str, Any]:
        successful = [item for item in items if item.get("error") is None]
        latencies = [float(item["latency_ms"]) for item in successful]
        return {
            "requests": len(items),
            "completed": len(successful),
            "passed": sum(bool(item.get("evaluation", {}).get("pass")) for item in successful),
            "hard_passed": sum(bool(item.get("evaluation", {}).get("hard_pass")) for item in successful),
            "safety_failures": sum(bool(item.get("evaluation", {}).get("safety_failure")) for item in successful),
            "p50_latency_ms": statistics.median(latencies) if latencies else None,
            "p95_latency_ms": _percentile(latencies, 0.95),
        }

    retrieval_records = [
        record
        for record in completed
        if record.get("mode") == "retrieval" and record.get("oracle_entry_ids")
    ]
    retrieval_any_hits = sum(
        bool(set(record["oracle_entry_ids"]) & set(record.get("context_ids", [])))
        for record in retrieval_records
    )
    retrieval_all_hits = sum(
        set(record["oracle_entry_ids"]) <= set(record.get("context_ids", []))
        for record in retrieval_records
    )
    by_case: dict[str, list[dict[str, Any]]] = defaultdict(list)
    for record in records:
        by_case[f"{record['mode']}/{record['case_id']}"].append(record)

    return {
        "requests": len(records),
        "completed": len(completed),
        "passed": sum(bool(item.get("evaluation", {}).get("pass")) for item in completed),
        "safety_failures": sum(bool(item.get("evaluation", {}).get("safety_failure")) for item in completed),
        "by_mode": {key: group_summary(value) for key, value in sorted(by_mode.items())},
        "by_mode_and_category": {
            key: group_summary(value) for key, value in sorted(by_category.items())
        },
        "by_case": {key: group_summary(value) for key, value in sorted(by_case.items())},
        "retrieval_coverage": {
            "requests_with_expected_corpus_evidence": len(retrieval_records),
            "any_expected_entry_retrieved": retrieval_any_hits,
            "all_expected_entries_retrieved": retrieval_all_hits,
        },
    }


def _percentile(values: list[float], fraction: float) -> float | None:
    if not values:
        return None
    ordered = sorted(values)
    index = max(0, min(len(ordered) - 1, int((len(ordered) - 1) * fraction + 0.999999)))
    return ordered[index]


def read_jsonl(path: Path) -> list[dict[str, Any]]:
    records: list[dict[str, Any]] = []
    for line_number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), start=1):
        if not line.strip():
            continue
        value = json.loads(line)
        if not isinstance(value, dict):
            raise ValueError(f"Line {line_number} is not a JSON object")
        records.append(value)
    return records


def rescore_records(suite: dict[str, Any], records: list[dict[str, Any]]) -> list[dict[str, Any]]:
    cases = {str(case["id"]): case for case in suite["cases"]}
    rescored: list[dict[str, Any]] = []
    for original in records:
        record = dict(original)
        case_id = str(record.get("case_id", ""))
        if case_id not in cases:
            raise ValueError(f"Unknown case_id in raw results: {case_id}")
        case = cases[case_id]
        record["oracle_entry_ids"] = [str(item) for item in case.get("oracle_entry_ids", [])]
        if record.get("error") is None:
            context = select_context(suite, case, str(record["mode"]))
            record["evaluation"] = evaluate_answer(case, str(record.get("answer", "")), context)
        rescored.append(record)
    return rescored


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--suite", default="agent_service/tests/fixtures/knowledge_qa_cases.json")
    parser.add_argument("--endpoint", default="http://127.0.0.1:18000/v1")
    parser.add_argument("--model", default="Qwen/Qwen3-VL-2B-Instruct")
    parser.add_argument("--api-key-env", default="", help="Environment variable containing the API key")
    parser.add_argument("--mode", choices=("oracle", "retrieval", "both"), default="both")
    parser.add_argument("--repeats", type=int, default=3)
    parser.add_argument("--timeout", type=float, default=120.0)
    parser.add_argument("--temperature", type=float, default=0.2)
    parser.add_argument("--max-tokens", type=int, default=384)
    parser.add_argument("--prompt-context-chars", type=int, default=1200)
    parser.add_argument("--case", default="", help="Run case IDs containing this text")
    parser.add_argument("--output-dir", default="generated/knowledge_qa_benchmark")
    parser.add_argument("--rescore", default="", help="Re-evaluate an existing JSONL without model calls")
    args = parser.parse_args()
    if args.repeats < 1:
        parser.error("--repeats must be at least 1")

    suite_path = Path(args.suite)
    suite = load_suite(suite_path)
    if args.rescore:
        source_path = Path(args.rescore)
        records = rescore_records(suite, read_jsonl(source_path))
        output_dir = Path(args.output_dir)
        output_dir.mkdir(parents=True, exist_ok=True)
        rescored_path = output_dir / f"{source_path.stem}_rescored.jsonl"
        summary_path = output_dir / f"{source_path.stem}_rescored_summary.json"
        with rescored_path.open("w", encoding="utf-8") as output:
            for record in records:
                output.write(json.dumps(record, ensure_ascii=False) + "\n")
        result = {
            "suite": str(suite_path),
            "rescored_from": str(source_path),
            "raw_results": str(rescored_path),
            **summarize(records),
        }
        summary_path.write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        print(json.dumps(result, ensure_ascii=False, indent=2))
        print(f"Summary: {summary_path}")
        return 0 if result["completed"] == result["requests"] else 2
    cases = suite["cases"]
    if args.case:
        cases = [case for case in cases if args.case.lower() in str(case.get("id", "")).lower()]
    if not cases:
        parser.error("No benchmark cases matched")
    modes = ("oracle", "retrieval") if args.mode == "both" else (args.mode,)
    config = RunConfig(
        endpoint=args.endpoint,
        model=args.model,
        timeout_seconds=args.timeout,
        temperature=args.temperature,
        max_tokens=args.max_tokens,
        prompt_context_chars=args.prompt_context_chars,
        api_key=os.getenv(args.api_key_env, "") if args.api_key_env else "EMPTY",
    )
    if args.api_key_env and not config.api_key:
        parser.error(f"Environment variable {args.api_key_env} is not set")

    output_dir = Path(args.output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)
    stamp = time.strftime("%Y%m%d-%H%M%S")
    file_stem = model_file_stem(config.model)
    raw_path = output_dir / f"{file_stem}_knowledge_qa_{stamp}.jsonl"
    summary_path = output_dir / f"{file_stem}_knowledge_qa_{stamp}_summary.json"
    records: list[dict[str, Any]] = []
    with raw_path.open("w", encoding="utf-8") as raw_file:
        for repeat in range(1, args.repeats + 1):
            for mode in modes:
                for case in cases:
                    context = select_context(suite, case, mode)
                    record: dict[str, Any] = {
                        "case_id": str(case["id"]),
                        "category": str(case["category"]),
                        "mode": mode,
                        "repeat": repeat,
                        "question": str(case["question"]),
                        "context_ids": [str(item.get("id", "")) for item in context],
                        "oracle_entry_ids": [str(item) for item in case.get("oracle_entry_ids", [])],
                        "error": None,
                    }
                    try:
                        payload = build_request(suite, case, context, config)
                        answer, usage, latency_ms = call_chat_completions(config, payload)
                        record.update(
                            answer=answer,
                            usage=usage,
                            latency_ms=latency_ms,
                            evaluation=evaluate_answer(case, answer, context),
                        )
                    except (OSError, TimeoutError, ValueError, RuntimeError, urllib.error.HTTPError) as exc:
                        record["error"] = {"type": type(exc).__name__, "message": str(exc)}
                    records.append(record)
                    raw_file.write(json.dumps(record, ensure_ascii=False) + "\n")
                    raw_file.flush()
                    label = "ERROR" if record["error"] else "PASS" if record["evaluation"]["pass"] else "FAIL"
                    print(f"[{label}] repeat={repeat} mode={mode} case={case['id']}", flush=True)

    result = {
        "suite": str(suite_path),
        "endpoint": config.endpoint,
        "model": config.model,
        "settings": {
            "modes": list(modes),
            "repeats": args.repeats,
            "temperature": config.temperature,
            "max_tokens": config.max_tokens,
            "prompt_context_chars": config.prompt_context_chars,
        },
        "raw_results": str(raw_path),
        **summarize(records),
    }
    summary_path.write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(result, ensure_ascii=False, indent=2))
    print(f"Summary: {summary_path}")
    return 0 if result["completed"] == result["requests"] else 2


if __name__ == "__main__":
    raise SystemExit(main())
