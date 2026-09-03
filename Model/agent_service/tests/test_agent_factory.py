from __future__ import annotations

import importlib.util
import json
import unittest
from typing import Any
from unittest.mock import patch

from agent_service.action_entailment import ActionEntailment
from agent_service.agent_factory import (
    AgentFactory,
    ROUTING_DECISION_SYSTEM_MESSAGE,
    _extract_final_answer,
    _extract_selected_tool,
    _answer_from_tool_result,
    _tool_catalog,
)
from agent_service.config import Settings
from agent_service.connection_manager import ConnectionManager
from agent_service.knowledge_harness import KnowledgeAnswer, TrustedEvidenceStore


class FakeKnowledgeHarness:
    def __init__(self) -> None:
        self.calls: list[tuple[str, list[Any]]] = []

    def answer(self, question: str, entries: list[Any]) -> KnowledgeAnswer:
        self.calls.append((question, entries))
        return KnowledgeAnswer(
            answer="本地可验证答案。",
            decision="answer",
            citations=(),
            reason="test",
            retrieved_ids=(),
            model_attempts=0,
        )


class FakeActionEntailmentVerifier:
    def __init__(self, verdict: str = "entailed") -> None:
        self.verdict = verdict
        self.calls: list[tuple[str, str]] = []

    def verify(self, question: str, candidate_tool: str) -> ActionEntailment:
        self.calls.append((question, candidate_tool))
        return ActionEntailment(candidate_tool, self.verdict, "unit_test")


def selection_arguments(
    *,
    request_mode: str,
    target: str,
    operation: str,
    target_source: str = "explicit",
    arguments_grounded: bool = True,
    **arguments: Any,
) -> str:
    return json.dumps(
        {
            **arguments,
            "semantic_context": {
                "request_mode": request_mode,
                "target": target,
                "operation": operation,
                "target_source": target_source,
                "arguments_grounded": arguments_grounded,
            },
        },
        ensure_ascii=False,
    )


class AgentFactoryTests(unittest.TestCase):
    def test_untrusted_model_answer_is_never_extracted(self) -> None:
        raw = '{"ok":true,"data":{"answer":"未经验证的在线答案"},"error":null}'
        self.assertEqual(_answer_from_tool_result("query_task_knowledge", raw), "工具执行完成。")

    def test_current_task_step_result_is_rendered_as_a_grounded_answer(self) -> None:
        raw = json.dumps(
            {
                "ok": True,
                "data": {
                    "task_title": "无容器样品实验流程",
                    "page_index": 17,
                    "page_count": 20,
                    "current_step": {
                        "title": "17.固定机构",
                        "info": "使用2.5N·m的力矩锁紧6颗M6螺钉。",
                    },
                },
                "error": None,
            },
            ensure_ascii=False,
        )

        answer = _answer_from_tool_result("get_current_task_step", raw)

        self.assertIn("第 17 页", answer)
        self.assertIn("共 20 页", answer)
        self.assertIn("17.固定机构", answer)
        self.assertIn("2.5N·m", answer)
        self.assertNotEqual(answer, "工具执行完成。")

    def test_album_state_result_is_rendered_as_a_grounded_answer(self) -> None:
        raw = '{"ok":true,"data":{"page":3,"page_count":8},"error":null}'

        self.assertEqual(
            _answer_from_tool_result("get_album_state", raw),
            "当前相册在第 3 页，共 8 页。",
        )

    def test_extracts_last_assistant_answer(self) -> None:
        answer = _extract_final_answer(
            [
                {"role": "assistant", "content": "I will call a tool"},
                {"role": "function", "content": "{\"ok\": true}"},
                {"role": "assistant", "content": "相册已打开。"},
            ]
        )
        self.assertEqual(answer, "相册已打开。")

    def test_extracts_multimodal_text_content(self) -> None:
        answer = _extract_final_answer(
            [{"role": "assistant", "content": [{"text": "完成"}]}]
        )
        self.assertEqual(answer, "完成")

    def test_detects_first_function_result_without_waiting_for_second_inference(self) -> None:
        from agent_service.agent_factory import _contains_function_result

        self.assertFalse(
            _contains_function_result([{"role": "assistant", "content": ""}])
        )
        self.assertTrue(
            _contains_function_result(
                [{"role": "function", "name": "open_album", "content": "{}"}]
            )
        )

    def test_llm_config_targets_local_qwenvl_server(self) -> None:
        settings = Settings(
            model_name="local-test-model",
            model_server="http://127.0.0.1:9000/v1",
            api_key="test-key",
        )
        config = AgentFactory(settings, ConnectionManager())._llm_config()
        self.assertEqual(config["model_type"], "qwenvl_oai")
        self.assertEqual(config["model"], "local-test-model")
        self.assertEqual(config["model_server"], "http://127.0.0.1:9000/v1")
        self.assertEqual(config["api_key"], "test-key")
        self.assertEqual(config["generate_cfg"]["temperature"], 0.0)
        self.assertEqual(config["generate_cfg"]["fncall_prompt_type"], "nous")
        self.assertFalse(config["generate_cfg"]["use_raw_api"])
        self.assertEqual(Settings().knowledge_context_tool_timeout_seconds, 5.0)
        self.assertEqual(Settings().tool_semantic_timeout_seconds, 10.0)

    def test_llm_config_supports_text_models_and_native_tool_calls(self) -> None:
        settings = Settings(
            model_type="oai",
            model_use_raw_api=True,
            model_fncall_prompt_type="nous",
            model_enable_thinking=False,
        )

        config = AgentFactory(settings, ConnectionManager())._llm_config()

        self.assertEqual(config["model_type"], "oai")
        self.assertTrue(config["generate_cfg"]["use_raw_api"])
        self.assertEqual(
            config["generate_cfg"]["extra_body"],
            {"chat_template_kwargs": {"enable_thinking": False}},
        )

    @unittest.skipUnless(
        importlib.util.find_spec("qwen_agent") is not None,
        "qwen_agent is not installed in this Python environment",
    )
    def test_run_requests_a_structured_direct_decision(self) -> None:
        captured: dict[str, Any] = {}

        class FakeFnCallAgent:
            def __init__(self, **kwargs: Any) -> None:
                captured.update(kwargs)

            def run(self, **kwargs: Any) -> Any:
                captured["run"] = kwargs
                tool = next(
                    item
                    for item in captured["function_list"]
                    if item.name == "respond_directly"
                )
                result = tool.call(
                    selection_arguments(
                        request_mode="conversation",
                        target="none",
                        operation="respond",
                        target_source="not_applicable",
                        text="你好。",
                    )
                )
                yield [
                    {"role": "assistant", "content": ""},
                    {
                        "role": "function",
                        "name": "respond_directly",
                        "content": result,
                    },
                    {"role": "assistant", "content": "你好。"},
                ]

        factory = AgentFactory(Settings(), ConnectionManager())
        with patch("qwen_agent.agents.FnCallAgent", FakeFnCallAgent):
            result = factory.run(
                "session-1",
                "request-1",
                [{"role": "user", "content": "你好"}],
            )

        self.assertEqual(result.answer, "你好。")
        self.assertEqual(captured["llm"]["model_type"], "qwenvl_oai")
        self.assertEqual(
            [tool.name for tool in captured["function_list"]],
            ["open_album", "respond_directly", "clarify_ui_target"],
        )
        self.assertIn("工具名称、作用和参数定义", captured["system_message"])
        prompt = captured["run"]["messages"][0]["content"]
        self.assertTrue(prompt.startswith("你好\n"))
        self.assertIn("open_album", prompt)
        self.assertIn("respond_directly", prompt)
        self.assertIn("clarify_ui_target", prompt)
        self.assertNotIn('"parameters"', prompt)
        self.assertNotIn("打开 GodotSpace 相册界面", prompt)
        open_album = captured["function_list"][0]
        self.assertEqual(open_album.name, "open_album")
        self.assertTrue(open_album.description)
        self.assertIsInstance(open_album.parameters, dict)
        self.assertIn("semantic_context", open_album.parameters["properties"])
        self.assertIn("semantic_context", open_album.parameters["required"])
        self.assertEqual(captured["run"]["lang"], "zh")

    @unittest.skipUnless(
        importlib.util.find_spec("qwen_agent") is not None,
        "qwen_agent is not installed in this Python environment",
    )
    def test_run_allows_qwen_direct_response_tool(self) -> None:
        class FakeFnCallAgent:
            def __init__(self, **kwargs: Any) -> None:
                self._tools = kwargs["function_list"]

            def run(self, **_kwargs: Any) -> Any:
                tool = next(item for item in self._tools if item.name == "respond_directly")
                result = tool.call(
                    selection_arguments(
                        request_mode="conversation",
                        target="none",
                        operation="respond",
                        target_source="not_applicable",
                        text="你好。",
                    )
                )
                yield [
                    {"role": "assistant", "content": ""},
                    {
                        "role": "function",
                        "name": "respond_directly",
                        "content": result,
                    },
                    {"role": "assistant", "content": "你好。"},
                ]

        verifier = FakeActionEntailmentVerifier()
        factory = AgentFactory(
            Settings(),
            ConnectionManager(),
            action_entailment_verifier=verifier,
        )
        with patch("qwen_agent.agents.FnCallAgent", FakeFnCallAgent):
            result = factory.run(
                "session-1",
                "request-1",
                [{"role": "user", "content": "你好"}],
                ["query_task_knowledge"],
            )
        self.assertEqual(result.answer, "你好。")

    @unittest.skipUnless(
        importlib.util.find_spec("qwen_agent") is not None,
        "qwen_agent is not installed in this Python environment",
    )
    def test_native_tool_decision_is_dispatched(self) -> None:
        captured: dict[str, Any] = {}

        class FakeFnCallAgent:
            def __init__(self, **kwargs: Any) -> None:
                self._tools = kwargs["function_list"]

            def run(self, **_kwargs: Any) -> Any:
                tool_result = self._tools[0].call(
                    selection_arguments(
                        request_mode="execute",
                        target="task_guide",
                        operation="next",
                        target_source="context",
                    )
                )
                yield [
                    {
                        "role": "assistant",
                        "content": "",
                    },
                    {
                        "role": "function",
                        "name": "next_task_step",
                        "content": tool_result,
                    },
                    {"role": "assistant", "content": "操作完成。"},
                ]

        class FakeTool:
            name = "next_task_step"
            description = "将指导书推进一步。"
            parameters = {
                "type": "object",
                "properties": {},
                "required": [],
            }

            def call(self, arguments: str) -> str:
                captured["arguments"] = arguments
                return '{"ok":true,"data":{"snapshot":{"page_index":2}},"error":null}'

        verifier = FakeActionEntailmentVerifier()
        factory = AgentFactory(
            Settings(),
            ConnectionManager(),
            action_entailment_verifier=verifier,
        )
        with (
            patch("qwen_agent.agents.FnCallAgent", FakeFnCallAgent),
            patch.object(factory, "_build_tools", return_value=[FakeTool()]) as build_tools,
        ):
            result = factory.run(
                "session-1",
                "request-1",
                [{"role": "user", "content": "这一步我做完了，接下来需要做什么"}],
                ["next_task_step"],
            )

        self.assertEqual(result.route, "tool")
        self.assertEqual(result.tool_name, "next_task_step")
        self.assertEqual(captured["arguments"], {})
        self.assertIsNotNone(result.harness_trace)
        assert result.harness_trace is not None
        tool_trace = result.harness_trace.to_dict()
        self.assertEqual(tool_trace["version"], 1)
        self.assertEqual(len(tool_trace["stages"]), 1)
        self.assertEqual(tool_trace["stages"][0]["type"], "tool_call")
        self.assertEqual(tool_trace["stages"][0]["outcome"], "executed")
        self.assertEqual(
            tool_trace["stages"][0]["details"]["tool_name"],
            "next_task_step",
        )
        self.assertEqual(
            verifier.calls,
            [("这一步我做完了，接下来需要做什么", "next_task_step")],
        )
        build_tools.assert_called_once_with(
            "session-1",
            "request-1",
            ["next_task_step"],
        )

    @unittest.skipUnless(
        importlib.util.find_spec("qwen_agent") is not None,
        "qwen_agent is not installed in this Python environment",
    )
    def test_wrong_model_tool_has_no_side_effect_and_is_corrected(self) -> None:
        executed: list[str] = []

        class FakeFnCallAgent:
            def __init__(self, **kwargs: Any) -> None:
                self._tools = kwargs["function_list"]

            def run(self, **_kwargs: Any) -> Any:
                wrong = next(item for item in self._tools if item.name == "previous_task_step")
                selection = wrong.call(
                    selection_arguments(
                        request_mode="execute",
                        target="task_guide",
                        operation="next",
                    )
                )
                yield [
                    {"role": "assistant", "content": ""},
                    {
                        "role": "function",
                        "name": "previous_task_step",
                        "content": selection,
                    },
                ]

        class FakeTool:
            description = "测试工具"
            parameters = {"type": "object", "properties": {}, "required": []}

            def __init__(self, name: str) -> None:
                self.name = name

            def call(self, _arguments: dict[str, Any]) -> str:
                executed.append(self.name)
                return '{"ok":true,"data":{},"error":null}'

        verifier = FakeActionEntailmentVerifier()
        factory = AgentFactory(
            Settings(),
            ConnectionManager(),
            action_entailment_verifier=verifier,
        )
        tools = [FakeTool("next_task_step"), FakeTool("previous_task_step")]
        with (
            patch("qwen_agent.agents.FnCallAgent", FakeFnCallAgent),
            patch.object(factory, "_build_tools", return_value=tools),
        ):
            result = factory.run(
                "session-1",
                "request-1",
                [{"role": "user", "content": "指导书翻到下一页"}],
                ["next_task_step", "previous_task_step"],
            )

        self.assertEqual(executed, ["next_task_step"])
        self.assertEqual(result.tool_name, "next_task_step")
        self.assertTrue(result.tool_harness["corrected"])
        self.assertEqual(result.tool_harness["proposed_tool"], "previous_task_step")
        self.assertEqual(
            verifier.calls,
            [("指导书翻到下一页", "next_task_step")],
        )

    @unittest.skipUnless(
        importlib.util.find_spec("qwen_agent") is not None,
        "qwen_agent is not installed in this Python environment",
    )
    def test_knowledge_route_uses_local_harness_not_tool_answer(self) -> None:
        class FakeFnCallAgent:
            def __init__(self, **kwargs: Any) -> None:
                self._tools = kwargs["function_list"]

            def run(self, **_kwargs: Any) -> Any:
                tool = next(item for item in self._tools if item.name == "query_task_knowledge")
                result = tool.call(
                    selection_arguments(
                        request_mode="inquire",
                        target="knowledge",
                        operation="knowledge",
                        target_source="not_applicable",
                    )
                )
                yield [
                    {"role": "assistant", "content": ""},
                    {"role": "function", "name": "query_task_knowledge", "content": result},
                    {"role": "assistant", "content": "旧链路自由文本，不得展示。"},
                ]

        class FakeTool:
            name = "query_task_knowledge"
            description = "获取本地证据。"
            parameters = {"type": "object", "properties": {}, "required": []}

            def call(self, _arguments: str) -> str:
                return (
                    '{"ok":true,"data":{"answer":"伪造答案",'
                    '"entries":[{"id":"step-1","title":"当前步骤",'
                    '"content":"必须先确认断电。"}]},"error":null}'
                )

        harness = FakeKnowledgeHarness()
        factory = AgentFactory(
            Settings(),
            ConnectionManager(),
            knowledge_harness=harness,  # type: ignore[arg-type]
            knowledge_store=TrustedEvidenceStore(),
        )
        with (
            patch("qwen_agent.agents.FnCallAgent", FakeFnCallAgent),
            patch.object(factory, "_build_tools", return_value=[FakeTool()]),
        ):
            result = factory.run(
                "session-1",
                "request-1",
                [{"role": "user", "content": "现在能继续拆吗？"}],
                ["query_task_knowledge"],
            )

        self.assertEqual(result.answer, "本地可验证答案。")
        self.assertEqual(result.route, "knowledge_qa")
        self.assertEqual(result.tool_name, "query_task_knowledge")
        self.assertEqual(harness.calls[0][0], "现在能继续拆吗？")
        self.assertEqual(harness.calls[0][1][0].trust, "runtime")
        self.assertNotIn("伪造答案", result.answer)
        self.assertIsNotNone(result.harness_trace)
        assert result.harness_trace is not None
        trace = result.harness_trace.to_dict()
        self.assertEqual(
            [stage["type"] for stage in trace["stages"]],
            ["tool_call", "knowledge_qa"],
        )
        self.assertEqual(
            [stage["outcome"] for stage in trace["stages"]],
            ["executed", "answered"],
        )
        self.assertEqual(trace["stages"][1]["reason"], "test")

    def test_tool_catalog_exposes_trusted_description_and_strict_schema(self) -> None:
        class FakeTool:
            name = "previous_task_step"
            description = "将指导书返回上一步。"
            parameters = {
                "type": "object",
                "properties": {},
                "required": [],
            }

        catalog = _tool_catalog([FakeTool()])

        self.assertEqual(catalog[0]["name"], "previous_task_step")
        self.assertEqual(catalog[0]["description"], "将指导书返回上一步。")
        self.assertFalse(catalog[0]["parameters"]["additionalProperties"])

    def test_routing_prompt_contains_no_phrase_to_tool_mapping(self) -> None:
        self.assertNotIn("下一步应该做什么", ROUTING_DECISION_SYSTEM_MESSAGE)
        self.assertNotIn("next_task_step first", ROUTING_DECISION_SYSTEM_MESSAGE)
        self.assertNotIn("page_turn_target", ROUTING_DECISION_SYSTEM_MESSAGE)
        self.assertIn("工具名称、作用和参数定义", ROUTING_DECISION_SYSTEM_MESSAGE)
        self.assertIn("非标准或近似对象名称", ROUTING_DECISION_SYSTEM_MESSAGE)
        self.assertIn("唯一最接近项", ROUTING_DECISION_SYSTEM_MESSAGE)

    def test_rejects_multiple_selected_tools(self) -> None:
        with self.assertRaises(RuntimeError):
            _extract_selected_tool(
                [
                    {"role": "function", "name": "next_task_step", "content": "{}"},
                    {
                        "role": "function",
                        "name": "previous_task_step",
                        "content": "{}",
                    },
                ]
            )

    def test_extracts_one_native_qwen_tool_result(self) -> None:
        selected = _extract_selected_tool(
            [{"role": "function", "name": "next_task_step", "content": "{}"}]
        )
        self.assertEqual(selected, "next_task_step")

    @unittest.skipUnless(
        importlib.util.find_spec("qwen_agent") is not None,
        "qwen_agent is not installed in this Python environment",
    )
    def test_builds_only_the_authorized_task_tools(self) -> None:
        factory = AgentFactory(Settings(), ConnectionManager())
        tools = factory._build_tools(
            "session-1",
            "request-1",
            ["get_current_task_step", "next_task_step"],
        )

        self.assertEqual(
            [tool.name for tool in tools],
            ["get_current_task_step", "next_task_step"],
        )
        self.assertFalse(tools[0]._state_changing)
        self.assertTrue(tools[1]._state_changing)

    @unittest.skipUnless(
        importlib.util.find_spec("qwen_agent") is not None,
        "qwen_agent is not installed in this Python environment",
    )
    def test_builds_navigation_and_knowledge_tools(self) -> None:
        factory = AgentFactory(
            Settings(tool_timeout_seconds=3.0, knowledge_context_tool_timeout_seconds=47.0),
            ConnectionManager(),
        )
        tools = factory._build_tools(
            "session-1",
            "request-1",
            ["close_album", "go_to_album_page", "go_to_task_guide_page", "query_task_knowledge"],
        )
        self.assertEqual(
            [tool.name for tool in tools],
            ["close_album", "go_to_album_page", "go_to_task_guide_page", "query_task_knowledge"],
        )
        self.assertTrue(tools[0]._state_changing)
        self.assertTrue(tools[1]._state_changing)
        self.assertTrue(tools[2]._state_changing)
        self.assertFalse(tools[3]._state_changing)
        self.assertEqual(tools[0]._timeout_seconds, 3.0)
        self.assertEqual(tools[1]._timeout_seconds, 3.0)
        self.assertEqual(tools[2]._timeout_seconds, 3.0)
        self.assertEqual(tools[3]._timeout_seconds, 47.0)

        with self.assertRaisesRegex(ValueError, "Unsupported allowed tools"):
            factory._build_tools(
                "session-1",
                "request-legacy",
                ["delegate_" + "deepseek"],
            )

    @unittest.skipUnless(
        importlib.util.find_spec("qwen_agent") is not None,
        "qwen_agent is not installed in this Python environment",
    )
    def test_rejects_unsupported_authorized_tool(self) -> None:
        factory = AgentFactory(Settings(), ConnectionManager())
        with self.assertRaises(ValueError):
            factory._build_tools("session-1", "request-1", ["call_node"])


if __name__ == "__main__":
    unittest.main()
