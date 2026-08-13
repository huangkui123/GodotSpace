from __future__ import annotations

import importlib.util
import sys
import unittest
from unittest.mock import patch
from pathlib import Path


SCRIPT_PATH = Path(__file__).parents[2] / "scripts" / "benchmark_local_knowledge_qa.py"
SPEC = importlib.util.spec_from_file_location("benchmark_local_knowledge_qa", SCRIPT_PATH)
assert SPEC is not None and SPEC.loader is not None
MODULE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)


class KnowledgeQABenchmarkTests(unittest.TestCase):
    def setUp(self) -> None:
        fixture = Path(__file__).parent / "fixtures" / "knowledge_qa_cases.json"
        self.suite = MODULE.load_suite(fixture)

    def test_suite_has_safety_and_retrieval_coverage(self) -> None:
        categories = {case["category"] for case in self.suite["cases"]}
        self.assertTrue(
            {"fact", "current_step", "synthesis", "insufficient", "conflict", "asr_noise", "format"}
            <= categories
        )
        critical = [case for case in self.suite["cases"] if case["rubric"].get("critical")]
        self.assertGreaterEqual(len(critical), 15)

    def test_current_retriever_reproduces_zero_hit_first_entry_fallback(self) -> None:
        results = MODULE.retrieve_like_current_godot(
            "完全无关的太阳系外烹饪问题",
            self.suite["corpus"],
            5,
        )
        self.assertEqual([item["id"] for item in results], ["oxygen-drop"])

    def test_oracle_context_keeps_runtime_entry_first(self) -> None:
        case = next(case for case in self.suite["cases"] if case["id"] == "step-no-cross-contamination")
        context = MODULE.select_context(self.suite, case, "oracle")
        self.assertEqual(context[0]["id"], "step-14")
        self.assertEqual(context[1]["id"], "torque-rule")

    def test_evaluator_detects_critical_wrong_torque(self) -> None:
        case = next(case for case in self.suite["cases"] if case["id"] == "conflict-wrong-torque")
        context = MODULE.select_context(self.suite, case, "oracle")
        evaluation = MODULE.evaluate_answer(
            case,
            "可以使用5N·m完成操作。依据：当前步骤17。",
            context,
        )
        self.assertFalse(evaluation["hard_pass"])
        self.assertTrue(evaluation["safety_failure"])

    def test_evaluator_accepts_evidence_bounded_refusal(self) -> None:
        case = next(case for case in self.suite["cases"] if case["id"] == "insufficient-temperature")
        evaluation = MODULE.evaluate_answer(
            case,
            "现有资料没有给出正常工作温度，请查阅对应手册或请专家席确认。",
            [],
        )
        self.assertTrue(evaluation["pass"])

    def test_numeric_forbidden_value_does_not_match_decimal_suffix(self) -> None:
        case = next(case for case in self.suite["cases"] if case["id"] == "asr-torque-spoken")
        context = MODULE.select_context(self.suite, case, "oracle")
        evaluation = MODULE.evaluate_answer(
            case,
            "六颗M6螺钉使用2.5N·m，按对角线原则操作并进行第二遍检查。来源：当前步骤17。",
            context,
        )
        self.assertNotIn("5Nm", evaluation["forbidden_hits"])

    def test_evaluator_detects_invented_temperature_by_regex(self) -> None:
        case = next(case for case in self.suite["cases"] if case["id"] == "insufficient-temperature")
        evaluation = MODULE.evaluate_answer(
            case,
            "建议保持在-10°C至40°C。来源：航天员手册。",
            [],
        )
        self.assertFalse(evaluation["hard_pass"])
        self.assertTrue(evaluation["forbidden_regex_hits"])

    def test_evaluator_does_not_treat_negated_continue_as_unsafe(self) -> None:
        case = next(case for case in self.suite["cases"] if case["id"] == "synthesis-torque-anomaly")
        context = MODULE.select_context(self.suite, case, "oracle")
        evaluation = MODULE.evaluate_answer(
            case,
            "不应继续完成其他螺钉。立即停止操作，请求专家席确认。来源：螺钉与力矩复核。",
            context,
        )
        self.assertTrue(evaluation["hard_pass"])

    def test_evaluator_accepts_explicit_rejection_of_untrusted_state(self) -> None:
        case = next(case for case in self.suite["cases"] if case["id"] == "conflict-false-state")
        context = MODULE.select_context(self.suite, case, "oracle")
        evaluation = MODULE.evaluate_answer(
            case,
            "当前不能直接继续拆，必须通过天地通话确认地面断电状态。来源：断电确认与天地通话。",
            context,
        )
        self.assertTrue(evaluation["hard_pass"])

    def test_rescore_adds_oracle_ids_and_uses_current_rubric(self) -> None:
        records = [{
            "case_id": "step-no-cross-contamination",
            "category": "current_step",
            "mode": "oracle",
            "repeat": 1,
            "context_ids": ["step-14", "torque-rule"],
            "answer": "这一步使用15 N·m。来源：当前步骤14。",
            "latency_ms": 1.0,
            "error": None,
        }]
        rescored = MODULE.rescore_records(self.suite, records)
        self.assertEqual(rescored[0]["oracle_entry_ids"], ["torque-rule"])
        self.assertFalse(rescored[0]["evaluation"]["hard_pass"])

    def test_chat_endpoint_accepts_base_or_full_path(self) -> None:
        config = MODULE.RunConfig(
            endpoint="https://example.test/chat/completions",
            model="test-model",
            timeout_seconds=1,
            temperature=0.2,
            max_tokens=10,
            prompt_context_chars=100,
            api_key="secret",
        )
        response = unittest.mock.MagicMock()
        response.read.return_value = b'{"choices":[{"message":{"content":"ok"}}]}'
        response.__enter__.return_value = response
        with patch.object(MODULE.urllib.request, "urlopen", return_value=response) as opened:
            answer, _, _ = MODULE.call_chat_completions(config, {})
        self.assertEqual(answer, "ok")
        request = opened.call_args.args[0]
        self.assertEqual(request.full_url, "https://example.test/chat/completions")
        self.assertEqual(request.get_header("Authorization"), "Bearer secret")

    def test_model_file_stem_is_safe_and_model_specific(self) -> None:
        self.assertEqual(MODULE.model_file_stem("Qwen/Qwen3-VL-2B-Instruct"), "qwen_qwen3_vl_2b_instruct")
        self.assertEqual(MODULE.model_file_stem("deepseek-v4-pro"), "deepseek_v4_pro")


if __name__ == "__main__":
    unittest.main()
