from __future__ import annotations

import unittest
from contextlib import nullcontext
from types import SimpleNamespace
from unittest.mock import patch

from agent_service.action_entailment import (
    ActionEntailment,
    QwenActionEntailmentVerifier,
    SYSTEM_MESSAGE,
    final_intent_segment,
    has_explicit_contradiction_evidence,
    has_explicit_nonexecution_cue,
)
from agent_service.config import Settings


class ActionEntailmentTests(unittest.TestCase):
    def test_verifier_closes_client_without_automatic_retries_on_failure(self) -> None:
        with patch("openai.OpenAI") as factory:
            client = factory.return_value.__enter__.return_value
            client.chat.completions.create.side_effect = RuntimeError("unavailable")
            result = QwenActionEntailmentVerifier(Settings()).verify("让相册先退场一下", "close_album")
            self.assertEqual(result.verdict, "unclear")
            self.assertEqual(factory.call_args.kwargs["max_retries"], 0)
            factory.return_value.__exit__.assert_called_once()

    def test_mapping_parser_is_strict(self) -> None:
        valid = {
            "candidate_tool": "next_task_step",
            "verdict": "entailed",
            "reason": "test",
        }

        self.assertEqual("entailed", ActionEntailment.from_mapping(valid).verdict)  # type: ignore[union-attr]
        self.assertIsNone(ActionEntailment.from_mapping({**valid, "extra": True}))
        self.assertIsNone(ActionEntailment.from_mapping({**valid, "verdict": "yes"}))

    def test_model_verifier_returns_forced_tool_assessment(self) -> None:
        function = SimpleNamespace(
            name="verify_action_entailment",
            arguments='{"verdict":"entailed"}',
        )
        response = SimpleNamespace(
            choices=[
                SimpleNamespace(
                    message=SimpleNamespace(
                        tool_calls=[SimpleNamespace(function=function)]
                    )
                )
            ]
        )
        client = SimpleNamespace(
            chat=SimpleNamespace(
                completions=SimpleNamespace(create=lambda **_kwargs: response)
            )
        )

        with patch("openai.OpenAI", return_value=nullcontext(client)):
            result = QwenActionEntailmentVerifier(Settings()).verify(
                "带我往后走",
                "next_task_step",
            )

        self.assertEqual("entailed", result.verdict)
        self.assertEqual("next_task_step", result.candidate_tool)

    def test_explicit_target_commands_are_entailed_without_model(self) -> None:
        cases = (
            ("打开工作清单。", "open_task_guide"),
            ("打卡相册", "open_album"),
            ("指导书翻到下一页", "next_task_step"),
            ("相册返回上一页", "previous_album_page"),
            ("收起指导书", "close_task_guide"),
        )
        with patch("openai.OpenAI") as openai_client:
            results = [
                QwenActionEntailmentVerifier(Settings()).verify(text, tool)
                for text, tool in cases
            ]

        openai_client.assert_not_called()
        self.assertTrue(all(result.verdict == "entailed" for result in results))
        self.assertTrue(
            all(result.reason == "deterministic_explicit_command" for result in results)
        )

    def test_final_intent_cue_handling_preserves_double_negation(self) -> None:
        self.assertEqual("翻到下一页", final_intent_segment("我不是不要翻页，现在翻到下一页"))
        self.assertFalse(has_explicit_nonexecution_cue("我不是不要翻页，现在翻到下一页"))
        self.assertTrue(has_explicit_nonexecution_cue("现在不要翻到下一页"))
        self.assertTrue(has_explicit_nonexecution_cue("打开相册……算了，先别动界面"))

    def test_model_or_transport_failure_is_unclear(self) -> None:
        with patch("openai.OpenAI", side_effect=RuntimeError("offline")):
            result = QwenActionEntailmentVerifier(Settings()).verify(
                "继续",
                "next_task_step",
            )

        self.assertEqual("unclear", result.verdict)
        self.assertIn("verifier_error", result.reason)

    def test_unsubstantiated_model_contradiction_is_downgraded_to_unclear(self) -> None:
        function = SimpleNamespace(
            name="verify_action_entailment",
            arguments='{"verdict":"contradicted"}',
        )
        response = SimpleNamespace(
            choices=[
                SimpleNamespace(
                    message=SimpleNamespace(
                        tool_calls=[SimpleNamespace(function=function)]
                    )
                )
            ]
        )
        client = SimpleNamespace(
            chat=SimpleNamespace(
                completions=SimpleNamespace(create=lambda **_kwargs: response)
            )
        )

        with patch("openai.OpenAI", return_value=nullcontext(client)):
            result = QwenActionEntailmentVerifier(Settings()).verify(
                "关闭工作文档",
                "close_task_guide",
            )

        self.assertEqual("unclear", result.verdict)
        self.assertEqual(
            "model_contradiction_without_explicit_evidence",
            result.reason,
        )

    def test_explicit_conflict_preserves_model_contradiction(self) -> None:
        function = SimpleNamespace(
            name="verify_action_entailment",
            arguments='{"verdict":"contradicted"}',
        )
        response = SimpleNamespace(
            choices=[
                SimpleNamespace(
                    message=SimpleNamespace(
                        tool_calls=[SimpleNamespace(function=function)]
                    )
                )
            ]
        )
        client = SimpleNamespace(
            chat=SimpleNamespace(
                completions=SimpleNamespace(create=lambda **_kwargs: response)
            )
        )

        with patch("openai.OpenAI", return_value=nullcontext(client)):
            different_action = QwenActionEntailmentVerifier(Settings()).verify(
                "打开工作清单",
                "close_task_guide",
            )
            explicit_rejection = QwenActionEntailmentVerifier(Settings()).verify(
                "不要关闭工作清单",
                "close_task_guide",
            )

        self.assertEqual("contradicted", different_action.verdict)
        self.assertEqual("contradicted", explicit_rejection.verdict)
        self.assertTrue(
            has_explicit_contradiction_evidence(
                "打开工作清单", "close_task_guide"
            )
        )
        self.assertFalse(
            has_explicit_contradiction_evidence(
                "关闭工作文档", "close_task_guide"
            )
        )

    def test_verifier_prompt_requires_explicit_contradiction_evidence(self) -> None:
        self.assertIn("明确反证", SYSTEM_MESSAGE)
        self.assertIn("关闭工作文档", SYSTEM_MESSAGE)
        self.assertIn("关闭工作手册", SYSTEM_MESSAGE)
        self.assertIn("应判为 unclear", SYSTEM_MESSAGE)

    def test_unknown_candidate_fails_closed_without_model(self) -> None:
        result = QwenActionEntailmentVerifier(Settings()).verify(
            "执行未知操作",
            "call_arbitrary_method",
        )

        self.assertEqual("unclear", result.verdict)
        self.assertEqual("unknown_candidate_tool", result.reason)


if __name__ == "__main__":
    unittest.main()
