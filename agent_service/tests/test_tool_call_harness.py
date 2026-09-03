from __future__ import annotations

import unittest
from typing import Any

from agent_service.tool_call_harness import (
    SemanticFrame,
    ToolCallHarness,
    ToolProposal,
    normalize_tool_arguments,
    semantic_frame_schema,
)


def album_context(*, page: int = 2, page_count: int = 5) -> dict[str, object]:
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


def guide_context(*, page: int = 2, album_visible: bool = False) -> dict[str, object]:
    return {
        "album": {
            "visible": album_visible,
            "page": 2,
            "page_count": 5,
            "can_next": album_visible,
            "can_previous": album_visible,
        },
        "task_guide": {
            "visible": True,
            "task_id": 1,
            "page_index": page,
            "page_count": 5,
            "can_next": page < 5,
            "can_previous": page > 1,
        },
    }


def frame(
    request_mode: str,
    target: str,
    operation: str,
    *,
    target_source: str = "explicit",
    arguments_grounded: bool = True,
) -> dict[str, Any]:
    return {
        "request_mode": request_mode,
        "target": target,
        "operation": operation,
        "target_source": target_source,
        "arguments_grounded": arguments_grounded,
    }


def proposal(
    name: str,
    semantic_frame: dict[str, Any],
    arguments: dict[str, Any] | None = None,
    *,
    arguments_valid: bool = True,
    entailment: str | None = "entailed",
) -> ToolProposal:
    semantic_tools = {
        ("album", "open"): "open_album",
        ("album", "close"): "close_album",
        ("album", "next"): "next_album_page",
        ("album", "previous"): "previous_album_page",
        ("album", "go_to"): "go_to_album_page",
        ("task_guide", "open"): "open_task_guide",
        ("task_guide", "close"): "close_task_guide",
        ("task_guide", "next"): "next_task_step",
        ("task_guide", "previous"): "previous_task_step",
        ("task_guide", "go_to"): "go_to_task_guide_page",
        ("task_guide", "replay"): "replay_current_task_step",
    }
    candidate = semantic_tools.get(
        (semantic_frame.get("target"), semantic_frame.get("operation")),
        "",
    )
    action_entailment = (
        {
            "candidate_tool": candidate,
            "verdict": entailment,
            "reason": "unit_test",
        }
        if candidate
        and semantic_frame.get("request_mode") == "execute"
        and entailment is not None
        else {}
    )
    return ToolProposal(
        name=name,
        arguments=arguments or {},
        arguments_valid=arguments_valid,
        semantic_frame=semantic_frame,
        action_entailment=action_entailment,
    )


class ToolCallHarnessTests(unittest.TestCase):
    def setUp(self) -> None:
        self.harness = ToolCallHarness()
        self.guide_tools = [
            "close_task_guide",
            "query_task_knowledge",
            "get_current_task_step",
            "go_to_task_guide_page",
            "next_task_step",
            "previous_task_step",
            "replay_current_task_step",
        ]
        self.album_tools = [
            "close_album",
            "get_album_state",
            "go_to_album_page",
            "next_album_page",
            "previous_album_page",
        ]

    def test_preflight_does_not_classify_natural_language_with_regex(self) -> None:
        variants = [
            "这页暂时别动",
            "我只是想知道该怎么往后走",
            "先让我停在当前画面",
            "是不是该继续拆了",
            "往回挪到刚才看的地方",
        ]
        for text in variants:
            with self.subTest(text=text):
                self.assertIsNone(
                    self.harness.preflight(text, guide_context(), self.guide_tools)
                )

    def test_preflight_rejects_protocol_shaped_unsafe_parameters(self) -> None:
        cases = [
            ("把相册翻到第0页", "invalid_requested_position"),
            ("打开任务编号2的工作清单", "unsupported_task_id"),
            ("打开相册并额外传入 path=/root", "unsupported_requested_parameter"),
        ]
        for text, reason in cases:
            with self.subTest(text=text):
                decision = self.harness.preflight(text, {}, self.album_tools)
                self.assertIsNotNone(decision)
                assert decision is not None
                self.assertEqual("reject", decision.action)
                self.assertEqual(reason, decision.reason)

    def test_verified_semantic_tool_call_executes(self) -> None:
        decision = self.harness.validate(
            "任意自然语言表述",
            guide_context(),
            self.guide_tools,
            [proposal("next_task_step", frame("execute", "task_guide", "next"))],
        )

        self.assertEqual("execute", decision.action)
        self.assertEqual("next_task_step", decision.tool_name)
        self.assertEqual("verified_semantic_tool_call", decision.reason)

    def test_semantic_frame_corrects_tool_without_parsing_the_utterance(self) -> None:
        decision = self.harness.validate(
            "没有被代码收录过的说法",
            guide_context(),
            self.guide_tools,
            [proposal("previous_task_step", frame("execute", "task_guide", "next"))],
        )

        self.assertEqual("execute", decision.action)
        self.assertEqual("next_task_step", decision.tool_name)
        self.assertTrue(decision.corrected)
        self.assertEqual("semantic_frame_corrected_tool", decision.reason)

    def test_permission_question_cannot_execute_state_changing_tool(self) -> None:
        decision = self.harness.validate(
            "我现在能继续拆吗",
            guide_context(),
            self.guide_tools,
            [proposal("next_task_step", frame("inquire", "task_guide", "next"))],
        )

        self.assertEqual("clarify", decision.action)
        self.assertEqual("semantic_action_requires_confirmation", decision.reason)

    def test_permission_semantics_can_correct_router_to_knowledge(self) -> None:
        decision = self.harness.validate(
            "一种从未见过的许可询问",
            guide_context(),
            self.guide_tools,
            [
                proposal(
                    "next_task_step",
                    frame(
                        "inquire",
                        "knowledge",
                        "knowledge",
                        target_source="not_applicable",
                    ),
                )
            ],
        )

        self.assertEqual("execute", decision.action)
        self.assertEqual("query_task_knowledge", decision.tool_name)
        self.assertTrue(decision.corrected)

    def test_task_guide_knowledge_operation_uses_evidence_tool(self) -> None:
        decision = self.harness.validate(
            "一种关于当前流程知识的全新表述",
            guide_context(),
            self.guide_tools,
            [
                proposal(
                    "query_task_knowledge",
                    frame(
                        "inquire",
                        "task_guide",
                        "knowledge",
                        target_source="context",
                    ),
                )
            ],
        )

        self.assertEqual("execute", decision.action)
        self.assertEqual("query_task_knowledge", decision.tool_name)

    def test_how_to_question_corrects_read_state_to_knowledge(self) -> None:
        decision = self.harness.validate(
            "这步咋弄",
            guide_context(),
            self.guide_tools,
            [
                proposal(
                    "get_current_task_step",
                    frame(
                        "inquire",
                        "task_guide",
                        "read_state",
                        target_source="context",
                    ),
                )
            ],
        )

        self.assertEqual("execute", decision.action)
        self.assertEqual("query_task_knowledge", decision.tool_name)
        self.assertTrue(decision.corrected)

    def test_closed_panel_navigation_without_page_resolves_to_open(self) -> None:
        closed_context = {
            "album": {"visible": False},
            "task_guide": {"visible": False},
        }
        semantic = frame("execute", "album", "go_to")
        proposed = ToolProposal(
            name="respond_directly",
            arguments={"text": ""},
            semantic_frame=semantic,
            action_entailment={
                "candidate_tool": "open_album",
                "verdict": "entailed",
                "reason": "unit_test",
            },
        )

        decision = self.harness.validate(
            "打卡相册",
            closed_context,
            ["query_task_knowledge", "open_album", "open_task_guide"],
            [proposed],
        )

        self.assertEqual("execute", decision.action)
        self.assertEqual("open_album", decision.tool_name)
        self.assertEqual({"page": 1, "refresh": True}, decision.arguments)

    def test_closed_panel_navigation_keeps_explicit_page_semantics(self) -> None:
        closed_context = {
            "album": {"visible": False},
            "task_guide": {"visible": False},
        }
        decision = self.harness.validate(
            "相册跳到第三页",
            closed_context,
            ["open_album"],
            [proposal("respond_directly", frame("execute", "album", "go_to"))],
        )

        self.assertEqual("reject", decision.action)
        self.assertEqual("semantic_tool_not_authorized", decision.reason)

    def test_non_executable_semantics_never_dispatch(self) -> None:
        decision = self.harness.validate(
            "任意否定、引用或假设表达",
            guide_context(),
            self.guide_tools,
            [
                proposal(
                    "next_task_step",
                    frame("non_executable", "task_guide", "next"),
                )
            ],
        )

        self.assertEqual("respond", decision.action)
        self.assertEqual("semantic_non_executable_request", decision.reason)

    def test_explicit_non_execution_cue_vetoes_a_doubly_wrong_model(self) -> None:
        decision = self.harness.validate(
            "不要翻到下一页",
            guide_context(),
            self.guide_tools,
            [
                proposal(
                    "previous_task_step",
                    frame("execute", "task_guide", "previous"),
                    entailment="entailed",
                )
            ],
        )

        self.assertEqual("respond", decision.action)
        self.assertEqual("explicit_non_execution_safety_veto", decision.reason)

    def test_final_explicit_command_survives_earlier_double_negation(self) -> None:
        decision = self.harness.validate(
            "我不是不要翻页，现在翻到下一页",
            guide_context(),
            self.guide_tools,
            [
                proposal(
                    "next_task_step",
                    frame("execute", "task_guide", "next"),
                    entailment="entailed",
                )
            ],
        )

        self.assertEqual("execute", decision.action)
        self.assertEqual("next_task_step", decision.tool_name)

    def test_both_visible_panels_require_explicit_target_grounding(self) -> None:
        decision = self.harness.validate(
            "往后走",
            guide_context(album_visible=True),
            [*self.guide_tools, *self.album_tools],
            [
                proposal(
                    "next_task_step",
                    frame(
                        "execute",
                        "task_guide",
                        "next",
                        target_source="context",
                    ),
                )
            ],
        )

        self.assertEqual("clarify", decision.action)
        self.assertEqual("ambiguous_visible_targets", decision.reason)

    def test_both_visible_nearest_candidate_with_unclear_entailment_is_confirmable(
        self,
    ) -> None:
        decision = self.harness.validate(
            "关闭工作手册",
            guide_context(album_visible=True),
            [*self.guide_tools, *self.album_tools],
            [
                proposal(
                    "close_task_guide",
                    frame(
                        "execute",
                        "task_guide",
                        "close",
                        target_source="context",
                    ),
                    entailment="unclear",
                )
            ],
        )

        self.assertEqual("clarify", decision.action)
        self.assertEqual("candidate_action_nearest_target", decision.reason)
        self.assertEqual("close_task_guide", decision.suggested_tool)
        self.assertEqual({}, decision.suggested_arguments)
        self.assertIn("关闭工作清单", decision.answer)

    def test_fuzzy_page_target_preserves_grounded_page_in_confirmation(self) -> None:
        decision = self.harness.validate(
            "翻到工作手册的第3页",
            guide_context(album_visible=True),
            [*self.guide_tools, *self.album_tools],
            [
                proposal(
                    "go_to_task_guide_page",
                    frame(
                        "execute",
                        "task_guide",
                        "go_to",
                        target_source="context",
                        arguments_grounded=True,
                    ),
                    {"page": 3},
                    entailment="unclear",
                )
            ],
        )

        self.assertEqual("clarify", decision.action)
        self.assertEqual("candidate_action_nearest_target", decision.reason)
        self.assertEqual("go_to_task_guide_page", decision.suggested_tool)
        self.assertEqual({"page": 3}, decision.suggested_arguments)
        self.assertIn("翻到工作清单第 3 页", decision.answer)

    def test_noncanonical_page_target_cannot_execute_when_verifier_entails(self) -> None:
        decision = self.harness.validate(
            "翻到照片簿的第4页",
            guide_context(album_visible=True),
            [*self.guide_tools, *self.album_tools],
            [
                proposal(
                    "go_to_album_page",
                    frame(
                        "execute",
                        "album",
                        "go_to",
                        target_source="explicit",
                        arguments_grounded=True,
                    ),
                    {"page": 4},
                    entailment="entailed",
                )
            ],
        )

        self.assertEqual("clarify", decision.action)
        self.assertEqual("candidate_action_approximate_target", decision.reason)
        self.assertEqual("go_to_album_page", decision.suggested_tool)
        self.assertEqual({"page": 4}, decision.suggested_arguments)
        self.assertIn("翻到相册第 4 页", decision.answer)

    def test_both_visible_panels_accept_model_grounded_explicit_target(self) -> None:
        decision = self.harness.validate(
            "一种明确指向照片但代码不认识的说法",
            guide_context(album_visible=True),
            [*self.guide_tools, *self.album_tools],
            [proposal("next_album_page", frame("execute", "album", "next"))],
        )

        self.assertEqual("execute", decision.action)
        self.assertEqual("next_album_page", decision.tool_name)

    def test_both_visible_panels_correct_model_context_when_target_is_explicit(self) -> None:
        decision = self.harness.validate(
            "流程说明退回刚才那项",
            guide_context(album_visible=True),
            [*self.guide_tools, *self.album_tools],
            [
                proposal(
                    "previous_task_step",
                    frame(
                        "execute",
                        "task_guide",
                        "previous",
                        target_source="context",
                    ),
                )
            ],
        )

        self.assertEqual("execute", decision.action)
        self.assertEqual("previous_task_step", decision.tool_name)

    def test_page_argument_must_be_semantically_grounded(self) -> None:
        decision = self.harness.validate(
            "定位过去",
            album_context(),
            self.album_tools,
            [
                proposal(
                    "go_to_album_page",
                    frame(
                        "execute",
                        "album",
                        "go_to",
                        arguments_grounded=False,
                    ),
                    {"page": 4},
                )
            ],
        )

        self.assertEqual("clarify", decision.action)
        self.assertEqual("tool_arguments_not_grounded", decision.reason)

    def test_missing_or_extra_semantic_fields_fail_closed(self) -> None:
        for invalid in ({}, {**frame("execute", "task_guide", "next"), "extra": True}):
            with self.subTest(invalid=invalid):
                decision = self.harness.validate(
                    "继续",
                    guide_context(),
                    self.guide_tools,
                    [proposal("next_task_step", invalid)],
                )
                self.assertEqual("reject", decision.action)
                self.assertEqual("missing_or_invalid_semantic_frame", decision.reason)

    def test_state_change_requires_independent_action_entailment(self) -> None:
        missing = self.harness.validate(
            "任意状态修改表达",
            guide_context(),
            self.guide_tools,
            [
                proposal(
                    "next_task_step",
                    frame("execute", "task_guide", "next"),
                    entailment=None,
                )
            ],
        )
        contradicted = self.harness.validate(
            "指导书翻到上一步",
            guide_context(),
            self.guide_tools,
            [
                proposal(
                    "next_task_step",
                    frame("execute", "task_guide", "next"),
                    entailment="contradicted",
                )
            ],
        )

        self.assertEqual("missing_or_invalid_action_entailment", missing.reason)
        self.assertEqual("candidate_action_contradicted", contradicted.reason)
        self.assertEqual("respond", contradicted.action)
        trace = contradicted.to_stage_trace(
            model_attempts=1,
            semantic_verifier_attempts=1,
            latency_ms=15.26,
        ).to_dict()
        self.assertEqual(trace["type"], "tool_call")
        self.assertEqual(trace["outcome"], "answered")
        self.assertTrue(trace["fallback_used"])
        self.assertEqual(trace["latency_ms"], 15.3)
        self.assertEqual(trace["details"]["semantic_verifier_attempts"], 1)

    def test_model_selected_nearest_option_becomes_confirmable_suggestion(self) -> None:
        context = {
            "album": {"visible": False},
            "task_guide": {"visible": False},
        }
        decision = self.harness.validate(
            "打开工作文档",
            context,
            ["open_task_guide"],
            [
                proposal(
                    "open_task_guide",
                    frame("execute", "task_guide", "open"),
                    {"task_id": 1},
                    entailment="unclear",
                )
            ],
        )

        self.assertEqual("clarify", decision.action)
        self.assertEqual("candidate_action_not_entailed", decision.reason)
        self.assertEqual("open_task_guide", decision.suggested_tool)
        self.assertEqual({"task_id": 1}, decision.suggested_arguments)
        self.assertIn("打开工作清单", decision.answer)
        self.assertNotIn("不能确认你是否希望现在执行", decision.answer)

    def test_unsubstantiated_contradiction_becomes_confirmable_suggestion(self) -> None:
        decision = self.harness.validate(
            "关闭工作文档",
            guide_context(),
            self.guide_tools,
            [
                proposal(
                    "close_task_guide",
                    frame("execute", "task_guide", "close"),
                    entailment="contradicted",
                )
            ],
        )

        self.assertEqual("clarify", decision.action)
        self.assertEqual(
            "candidate_action_contradiction_unsubstantiated",
            decision.reason,
        )
        self.assertEqual("close_task_guide", decision.suggested_tool)
        self.assertEqual({}, decision.suggested_arguments)
        self.assertIn("关闭工作清单", decision.answer)

    def test_fuzzy_guide_name_with_both_panels_becomes_confirmable_suggestion(self) -> None:
        decision = self.harness.validate(
            "关闭工作手册",
            {
                "album": {"visible": True, "page": 3, "page_count": 8},
                "task_guide": {"visible": True, "page_index": 4, "page_count": 20},
            },
            ["close_album", "close_task_guide"],
            [
                proposal(
                    "close_task_guide",
                    frame("execute", "task_guide", "close", target_source="approximate"),
                    entailment="entailed",
                )
            ],
        )

        self.assertEqual("clarify", decision.action)
        self.assertEqual("candidate_action_approximate_target", decision.reason)
        self.assertEqual("close_task_guide", decision.suggested_tool)
        self.assertEqual({}, decision.suggested_arguments)
        self.assertIn("关闭工作清单", decision.answer)
        self.assertNotIn("请明确要操作哪一个", decision.answer)

    def test_confirmed_suggestion_is_revalidated_against_current_state(self) -> None:
        hidden = {"album": {"visible": False}, "task_guide": {"visible": False}}
        execute = self.harness.validate_confirmed_action(
            hidden,
            ["open_task_guide"],
            "open_task_guide",
            {"task_id": 1},
        )
        unavailable = self.harness.validate_confirmed_action(
            hidden,
            ["open_album"],
            "open_task_guide",
            {"task_id": 1},
        )

        self.assertEqual("execute", execute.action)
        self.assertEqual("confirmed_pending_action", execute.reason)
        self.assertEqual("reject", unavailable.action)
        self.assertEqual("confirmed_action_no_longer_available", unavailable.reason)

    def test_malformed_arguments_and_multiple_calls_fail_closed(self) -> None:
        malformed = self.harness.validate(
            "继续",
            guide_context(),
            self.guide_tools,
            [
                proposal(
                    "next_task_step",
                    frame("execute", "task_guide", "next"),
                    arguments_valid=False,
                )
            ],
        )
        multiple = self.harness.validate(
            "继续",
            guide_context(),
            self.guide_tools,
            [
                proposal("next_task_step", frame("execute", "task_guide", "next")),
                proposal("previous_task_step", frame("execute", "task_guide", "previous")),
            ],
        )

        self.assertEqual("malformed_model_arguments", malformed.reason)
        self.assertEqual("multiple_model_tool_calls", multiple.reason)

    def test_model_omission_clarifies_instead_of_code_guessing(self) -> None:
        decision = self.harness.validate(
            "任何可能的操作",
            guide_context(),
            self.guide_tools,
            [],
        )

        self.assertEqual("clarify", decision.action)
        self.assertEqual("model_omitted_semantic_decision", decision.reason)

    def test_state_boundaries_and_hidden_panels_still_block_dispatch(self) -> None:
        last = self.harness.validate(
            "继续",
            guide_context(page=5),
            self.guide_tools,
            [proposal("next_task_step", frame("execute", "task_guide", "next"))],
        )
        hidden = self.harness.validate(
            "关闭",
            {"album": {"visible": False}},
            ["close_album"],
            [proposal("close_album", frame("execute", "album", "close"))],
        )

        self.assertEqual("already_at_last_position", last.reason)
        self.assertEqual("target_panel_not_visible", hidden.reason)

    def test_direct_conversation_uses_model_text_without_side_effect(self) -> None:
        decision = self.harness.validate(
            "你好",
            guide_context(),
            self.guide_tools,
            [
                proposal(
                    "respond_directly",
                    frame(
                        "conversation",
                        "none",
                        "respond",
                        target_source="not_applicable",
                    ),
                    {"text": "你好。"},
                )
            ],
        )

        self.assertEqual("respond", decision.action)
        self.assertEqual("你好。", decision.answer)

    def test_semantic_schema_and_frame_parser_are_strict(self) -> None:
        schema = semantic_frame_schema()
        parsed = SemanticFrame.from_mapping(frame("execute", "album", "next"))

        self.assertFalse(schema["additionalProperties"])
        self.assertEqual(5, len(schema["required"]))
        self.assertIn(
            "approximate",
            schema["properties"]["target_source"]["enum"],
        )
        self.assertIsNotNone(parsed)

    def test_open_album_arguments_are_normalized(self) -> None:
        arguments, error = normalize_tool_arguments("open_album", {})
        self.assertEqual("", error)
        self.assertEqual({"page": 1, "refresh": True}, arguments)


if __name__ == "__main__":
    unittest.main()
