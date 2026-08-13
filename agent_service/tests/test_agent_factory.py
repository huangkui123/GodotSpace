from __future__ import annotations

import importlib.util
import unittest
from typing import Any
from unittest.mock import patch

from agent_service.agent_factory import (
    AgentFactory,
    ROUTING_DECISION_SYSTEM_MESSAGE,
    _extract_final_answer,
    _extract_selected_tool,
    _explicit_page_tool,
    _is_negated_action,
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


class AgentFactoryTests(unittest.TestCase):
    def test_negated_actions_are_detected_before_model_tool_routing(self) -> None:
        self.assertTrue(_is_negated_action("不要翻页"))
        self.assertTrue(_is_negated_action("请取消打开相册"))
        self.assertFalse(_is_negated_action("打开相册"))
        self.assertFalse(_is_negated_action("为什么不能翻页？"))
        self.assertFalse(_is_negated_action("我不是不要翻页"))

    def test_explicit_page_is_resolved_only_with_an_unambiguous_target(self) -> None:
        self.assertEqual(
            _explicit_page_tool("翻到第三页", ["go_to_album_page"]),
            ("go_to_album_page", 3),
        )
        self.assertEqual(
            _explicit_page_tool(
                "相册翻到第三页",
                ["go_to_album_page", "go_to_task_guide_page"],
            ),
            ("go_to_album_page", 3),
        )
        self.assertIsNone(
            _explicit_page_tool(
                "翻到第三页",
                ["go_to_album_page", "go_to_task_guide_page"],
            )
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
                result = tool.call('{"text":"你好。"}')
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
        open_album = captured["function_list"][0]
        self.assertEqual(open_album.name, "open_album")
        self.assertTrue(open_album.description)
        self.assertIsInstance(open_album.parameters, dict)
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
                result = tool.call('{"text":"你好。"}')
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
                ["delegate_deepseek"],
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
                tool_result = self._tools[0].call("{}")
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

        factory = AgentFactory(Settings(), ConnectionManager())
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
        self.assertEqual(captured["arguments"], "{}")
        build_tools.assert_called_once_with(
            "session-1",
            "request-1",
            ["next_task_step"],
        )

    @unittest.skipUnless(
        importlib.util.find_spec("qwen_agent") is not None,
        "qwen_agent is not installed in this Python environment",
    )
    def test_deepseek_route_uses_local_harness_not_tool_answer(self) -> None:
        class FakeFnCallAgent:
            def __init__(self, **kwargs: Any) -> None:
                self._tools = kwargs["function_list"]

            def run(self, **_kwargs: Any) -> Any:
                tool = next(item for item in self._tools if item.name == "delegate_deepseek")
                result = tool.call("{}")
                yield [
                    {"role": "assistant", "content": ""},
                    {"role": "function", "name": "delegate_deepseek", "content": result},
                    {"role": "assistant", "content": "旧 DeepSeek 自由文本，不得展示。"},
                ]

        class FakeTool:
            name = "delegate_deepseek"
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
                ["delegate_deepseek"],
            )

        self.assertEqual(result.answer, "本地可验证答案。")
        self.assertEqual(harness.calls[0][0], "现在能继续拆吗？")
        self.assertEqual(harness.calls[0][1][0].trust, "runtime")
        self.assertNotIn("伪造答案", result.answer)

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
    def test_builds_navigation_and_deepseek_tools(self) -> None:
        factory = AgentFactory(
            Settings(tool_timeout_seconds=3.0, knowledge_context_tool_timeout_seconds=47.0),
            ConnectionManager(),
        )
        tools = factory._build_tools(
            "session-1",
            "request-1",
            ["close_album", "go_to_album_page", "go_to_task_guide_page", "delegate_deepseek"],
        )
        self.assertEqual(
            [tool.name for tool in tools],
            ["close_album", "go_to_album_page", "go_to_task_guide_page", "delegate_deepseek"],
        )
        self.assertTrue(tools[0]._state_changing)
        self.assertTrue(tools[1]._state_changing)
        self.assertTrue(tools[2]._state_changing)
        self.assertFalse(tools[3]._state_changing)
        self.assertEqual(tools[0]._timeout_seconds, 3.0)
        self.assertEqual(tools[1]._timeout_seconds, 3.0)
        self.assertEqual(tools[2]._timeout_seconds, 3.0)
        self.assertEqual(tools[3]._timeout_seconds, 47.0)

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
