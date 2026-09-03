from __future__ import annotations

import unittest
from pathlib import Path

from agent_service.tool_call_harness import (
    STATE_CHANGING_TOOLS,
    ToolCallHarness,
    ToolProposal,
)
from scripts.benchmark_tool_call_harness import (
    DEFAULT_SUITE,
    BenchmarkCase,
    evaluate_result,
    load_suite,
    summarize,
)


class ToolCallBenchmarkTests(unittest.TestCase):
    def test_fixture_is_large_and_covers_failure_categories(self) -> None:
        cases = load_suite(Path(DEFAULT_SUITE))

        self.assertGreaterEqual(len(cases), 50)
        self.assertEqual(len(cases), len({case.case_id for case in cases}))
        categories = {case.category for case in cases}
        self.assertTrue(
            {
                "baseline",
                "parameters",
                "knowledge",
                "asr",
                "negation",
                "hypothetical",
                "ambiguity",
                "invalid",
                "state_boundary",
                "unknown",
            }.issubset(categories)
        )

    def test_every_fixture_expectation_is_supported_by_the_harness(self) -> None:
        harness = ToolCallHarness()
        failures: list[str] = []
        tool_semantics = {
            "open_album": ("album", "open"),
            "close_album": ("album", "close"),
            "next_album_page": ("album", "next"),
            "previous_album_page": ("album", "previous"),
            "go_to_album_page": ("album", "go_to"),
            "get_album_state": ("album", "read_state"),
            "open_task_guide": ("task_guide", "open"),
            "close_task_guide": ("task_guide", "close"),
            "next_task_step": ("task_guide", "next"),
            "previous_task_step": ("task_guide", "previous"),
            "go_to_task_guide_page": ("task_guide", "go_to"),
            "get_current_task_step": ("task_guide", "read_state"),
            "replay_current_task_step": ("task_guide", "replay"),
            "query_task_knowledge": ("knowledge", "knowledge"),
        }
        for case in load_suite(Path(DEFAULT_SUITE)):
            decision = harness.preflight(case.text, case.context, case.allowed_tools)
            if decision is None:
                if case.expected_suggested_tool:
                    target, operation = tool_semantics[case.expected_suggested_tool]
                    proposals = [
                        ToolProposal(
                            case.expected_suggested_tool,
                            case.expected_suggested_arguments or {},
                            semantic_frame={
                                "request_mode": "execute",
                                "target": target,
                                "operation": operation,
                                "target_source": "explicit",
                                "arguments_grounded": True,
                            },
                            action_entailment={
                                "candidate_tool": case.expected_suggested_tool,
                                "verdict": "unclear",
                                "reason": "fixture_contract",
                            },
                        )
                    ]
                elif case.expected_tool:
                    target, operation = tool_semantics[case.expected_tool]
                    request_mode = (
                        "inquire"
                        if case.expected_tool
                        in {"query_task_knowledge", "get_album_state", "get_current_task_step"}
                        else "execute"
                    )
                    semantic_frame = {
                        "request_mode": request_mode,
                        "target": target,
                        "operation": operation,
                        "target_source": (
                            "not_applicable" if target == "knowledge" else "explicit"
                        ),
                        "arguments_grounded": True,
                    }
                    proposals = [
                        ToolProposal(
                            case.expected_tool,
                            case.expected_arguments or {},
                            semantic_frame=semantic_frame,
                            action_entailment=(
                                {
                                    "candidate_tool": case.expected_tool,
                                    "verdict": "entailed",
                                    "reason": "fixture_contract",
                                }
                                if case.expected_tool in STATE_CHANGING_TOOLS
                                else {}
                            ),
                        )
                    ]
                elif case.expected_route == "clarify" or (
                    case.expected_routes and "clarify" in case.expected_routes
                ):
                    proposals = [
                        ToolProposal(
                            "clarify_ui_target",
                            {"text": "请进一步说明。"},
                            semantic_frame={
                                "request_mode": "unclear",
                                "target": "unclear",
                                "operation": "clarify",
                                "target_source": "unclear",
                                "arguments_grounded": True,
                            },
                        )
                    ]
                else:
                    proposals = [
                        ToolProposal(
                            "respond_directly",
                            {"text": "好的。"},
                            semantic_frame={
                                "request_mode": (
                                    "non_executable"
                                    if case.mutation_forbidden
                                    else "conversation"
                                ),
                                "target": "none",
                                "operation": "respond",
                                "target_source": "not_applicable",
                                "arguments_grounded": True,
                            },
                        )
                    ]
                decision = harness.validate(
                    case.text,
                    case.context,
                    case.allowed_tools,
                    proposals,
                )
            route = (
                "knowledge_qa"
                if decision.action == "execute" and decision.tool_name == "query_task_knowledge"
                else "tool"
                if decision.action == "execute"
                else "confirm_action"
                if decision.action == "clarify" and decision.suggested_tool
                else "clarify"
                if decision.action == "clarify"
                else "direct_answer"
            )
            if case.expected_tool:
                matches = (
                    decision.action == "execute"
                    and decision.tool_name == case.expected_tool
                    and decision.arguments == (case.expected_arguments or {})
                ) or route in case.safe_fallback_routes
            elif case.expected_suggested_tool:
                matches = (
                    decision.action == "clarify"
                    and decision.suggested_tool == case.expected_suggested_tool
                    and decision.suggested_arguments
                    == (case.expected_suggested_arguments or {})
                    and route == case.expected_route
                )
            else:
                accepted_routes = case.expected_routes or (case.expected_route,)
                matches = route in accepted_routes
            if not matches:
                failures.append(
                    f"{case.case_id}: action={decision.action} "
                    f"tool={decision.tool_name} args={decision.arguments} route={route}"
                )

        self.assertEqual([], failures)

    def test_evaluator_checks_confirmable_model_suggestion(self) -> None:
        case = BenchmarkCase(
            case_id="fuzzy-work-document",
            category="regression",
            text="打开工作文档",
            context={},
            allowed_tools=["open_task_guide"],
            expected_route="confirm_action",
            expected_suggested_tool="open_task_guide",
            expected_suggested_arguments={"task_id": 1},
            expected_answer_contains=("打开工作清单",),
            mutation_forbidden=True,
        )
        result = evaluate_result(
            case,
            {
                "tool_calls": [],
                "assistant_final": {
                    "answer": "当前最接近的是“打开工作清单”，你是想执行它吗？",
                    "route": "confirm_action",
                    "tool_harness": {
                        "action": "clarify",
                        "reason": "candidate_action_not_entailed",
                        "suggested_tool": "open_task_guide",
                        "suggested_arguments": {"task_id": 1},
                    },
                    "harness_trace": {
                        "version": 1,
                        "stages": [{"type": "tool_call", "outcome": "clarified"}],
                    },
                },
            },
        )

        self.assertTrue(result["passed"])
        self.assertEqual(result["suggested_tool"], "open_task_guide")

    def test_evaluator_separates_wrong_proposal_from_corrected_dispatch(self) -> None:
        case = BenchmarkCase(
            case_id="direction",
            category="baseline",
            text="指导书翻到下一页",
            context={},
            allowed_tools=["next_task_step", "previous_task_step"],
            expected_tool="next_task_step",
            expected_arguments={},
        )

        result = evaluate_result(
            case,
            {
                "tool_calls": [{"name": "next_task_step", "arguments": {}}],
                "assistant_final": {
                    "route": "tool",
                    "tool_harness": {
                        "action": "execute",
                        "reason": "deterministic_correction:model_selected_wrong_tool",
                        "proposed_tool": "previous_task_step",
                        "proposed_arguments": {},
                        "corrected": True,
                        "model_attempts": 1,
                    },
                    "harness_trace": {
                        "version": 1,
                        "stages": [
                            {
                                "type": "tool_call",
                                "outcome": "executed",
                                "reason": "semantic_frame_corrected_tool",
                                "model_attempts": 1,
                                "fallback_used": False,
                                "latency_ms": 10.0,
                                "details": {},
                            }
                        ],
                    },
                },
            },
        )

        self.assertTrue(result["passed"])
        self.assertFalse(result["raw_exact"])
        self.assertTrue(result["corrected"])
        self.assertEqual("next_task_step", result["effective_tool"])
        self.assertEqual(result["harness_trace_version"], 1)
        self.assertEqual(result["harness_stages"][0]["outcome"], "executed")

    def test_evaluator_flags_a_forbidden_state_mutation(self) -> None:
        case = BenchmarkCase(
            case_id="negated",
            category="negation",
            text="不要翻页",
            context={},
            allowed_tools=["next_task_step"],
            expected_route="direct_answer",
            mutation_forbidden=True,
        )

        result = evaluate_result(
            case,
            {
                "tool_calls": [{"name": "next_task_step", "arguments": {}}],
                "assistant_final": {"route": "tool", "tool_harness": {}},
            },
        )

        self.assertFalse(result["passed"])
        self.assertTrue(result["false_mutation"])

    def test_evaluator_checks_the_user_visible_answer(self) -> None:
        case = BenchmarkCase(
            case_id="current-page",
            category="regression",
            text="我在工作文档的第几页",
            context={},
            allowed_tools=["get_current_task_step"],
            expected_tool="get_current_task_step",
            expected_arguments={},
            expected_answer_contains=("第 17 页",),
            forbidden_answer_contains=("工具执行完成",),
        )
        result = evaluate_result(
            case,
            {
                "tool_calls": [{"name": "get_current_task_step", "arguments": {}}],
                "assistant_final": {
                    "answer": "工具执行完成。",
                    "route": "tool",
                    "tool_harness": {
                        "action": "execute",
                        "reason": "verified_semantic_tool_call",
                    },
                    "harness_trace": {
                        "version": 1,
                        "stages": [{"type": "tool_call"}],
                    },
                },
            },
        )

        self.assertFalse(result["passed"])
        self.assertIn("answer missing required fragments: ['第 17 页']", result["errors"])
        self.assertIn("answer contains forbidden fragments: ['工具执行完成']", result["errors"])

    def test_evaluator_tracks_safe_degradation_separately(self) -> None:
        case = BenchmarkCase(
            case_id="self-correction",
            category="self_correction",
            text="往后，不对，回到前一页",
            context={},
            allowed_tools=["previous_album_page"],
            expected_tool="previous_album_page",
            expected_arguments={},
            safe_fallback_routes=("clarify", "direct_answer"),
        )

        result = evaluate_result(
            case,
            {
                "tool_calls": [],
                "assistant_final": {
                    "route": "clarify",
                    "tool_harness": {
                        "action": "clarify",
                        "reason": "candidate_action_not_entailed",
                    },
                    "harness_trace": {
                        "version": 1,
                        "stages": [
                            {
                                "type": "tool_call",
                                "outcome": "clarified",
                                "reason": "candidate_action_not_entailed",
                                "model_attempts": 1,
                                "fallback_used": True,
                                "latency_ms": 10.0,
                                "details": {},
                            }
                        ],
                    },
                },
            },
        )

        self.assertTrue(result["passed"])
        self.assertFalse(result["strict_passed"])
        self.assertTrue(result["degraded_safe_fallback"])

    def test_unlisted_state_change_fallback_is_a_failure(self) -> None:
        case = BenchmarkCase(
            case_id="baseline-next",
            category="baseline",
            text="指导书翻到下一页",
            context={},
            allowed_tools=["next_task_step"],
            expected_tool="next_task_step",
            expected_arguments={},
        )
        result = evaluate_result(
            case,
            {
                "tool_calls": [],
                "assistant_final": {
                    "route": "clarify",
                    "tool_harness": {
                        "action": "clarify",
                        "reason": "candidate_action_not_entailed",
                    },
                    "harness_trace": {
                        "version": 1,
                        "stages": [{"type": "tool_call"}],
                    },
                },
            },
        )

        self.assertFalse(result["passed"])
        self.assertFalse(result["strict_passed"])
        self.assertFalse(result["degraded_safe_fallback"])

    def test_evaluator_requires_harness_audit_metadata(self) -> None:
        case = BenchmarkCase(
            case_id="missing-trace",
            category="baseline",
            text="打开工作清单",
            context={},
            allowed_tools=["open_task_guide"],
            expected_tool="open_task_guide",
            expected_arguments={"task_id": 1},
        )
        result = evaluate_result(
            case,
            {
                "tool_calls": [
                    {"name": "open_task_guide", "arguments": {"task_id": 1}}
                ],
                "assistant_final": {
                    "route": "tool",
                    "tool_harness": {
                        "action": "execute",
                        "reason": "verified_semantic_tool_call",
                    },
                },
            },
        )

        self.assertFalse(result["passed"])
        self.assertIn("missing or unsupported harness_trace version", result["errors"])

    def test_summary_keeps_runtime_errors_in_category_denominators(self) -> None:
        summary = summarize(
            [
                {
                    "category": "ambiguity",
                    "transport_error": "RuntimeError",
                    "errors": ["context overflow"],
                },
                {
                    "category": "baseline",
                    "passed": True,
                    "strict_passed": True,
                    "latency_ms": 10.0,
                    "false_mutation": False,
                    "unauthorized_calls": [],
                },
            ]
        )

        self.assertEqual(1, summary["runtime_errors"])
        self.assertEqual(1, summary["by_category"]["ambiguity"]["total"])
        self.assertEqual(1, summary["by_category"]["ambiguity"]["runtime_errors"])
        self.assertEqual(0.0, summary["by_category"]["ambiguity"]["strict_pass_rate"])

    def test_summary_reports_effective_and_raw_rates_separately(self) -> None:
        summary = summarize(
            [
                {
                    "category": "baseline",
                    "passed": True,
                    "latency_ms": 10.0,
                    "raw_applicable": True,
                    "raw_exact": False,
                    "corrected": True,
                    "model_attempts": 1,
                    "false_mutation": False,
                    "unauthorized_calls": [],
                    "harness_reason": "deterministic_correction:model_selected_wrong_tool",
                },
                {
                    "category": "baseline",
                    "passed": True,
                    "latency_ms": 20.0,
                    "raw_applicable": True,
                    "raw_exact": True,
                    "corrected": False,
                    "model_attempts": 1,
                    "false_mutation": False,
                    "unauthorized_calls": [],
                    "harness_reason": "verified_model_tool_call",
                },
            ]
        )

        self.assertEqual(1.0, summary["effective_pass_rate"])
        self.assertEqual(0.0, summary["strict_pass_rate"])
        self.assertEqual(0.5, summary["raw_exact_rate"])
        self.assertEqual(1, summary["corrected"])
        self.assertEqual(20.0, summary["latency_ms"]["p95"])


if __name__ == "__main__":
    unittest.main()
