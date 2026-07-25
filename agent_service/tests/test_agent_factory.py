from __future__ import annotations

import importlib.util
import unittest
from typing import Any
from unittest.mock import patch

from agent_service.agent_factory import AgentFactory, _extract_final_answer
from agent_service.config import Settings
from agent_service.connection_manager import ConnectionManager


class AgentFactoryTests(unittest.TestCase):
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
        self.assertEqual(config["generate_cfg"]["fncall_prompt_type"], "nous")

    @unittest.skipUnless(
        importlib.util.find_spec("qwen_agent") is not None,
        "qwen_agent is not installed in this Python environment",
    )
    def test_run_registers_open_album_with_fncall_agent(self) -> None:
        captured: dict[str, Any] = {}

        class FakeFnCallAgent:
            def __init__(self, **kwargs: Any) -> None:
                captured.update(kwargs)

            def run(self, **kwargs: Any) -> Any:
                captured["run"] = kwargs
                captured["function_list"][0].call("{}")
                yield [{"role": "assistant", "content": "已完成。"}]

        factory = AgentFactory(Settings(), ConnectionManager())
        with patch("qwen_agent.agents.FnCallAgent", FakeFnCallAgent):
            result = factory.run(
                "session-1",
                "request-1",
                [{"role": "user", "content": "打开相册"}],
            )

        self.assertEqual(result.answer, "已完成。")
        self.assertEqual(captured["llm"]["model_type"], "qwenvl_oai")
        self.assertEqual(len(captured["function_list"]), 1)
        self.assertEqual(captured["function_list"][0].name, "open_album")
        self.assertEqual(captured["run"]["lang"], "zh")

    @unittest.skipUnless(
        importlib.util.find_spec("qwen_agent") is not None,
        "qwen_agent is not installed in this Python environment",
    )
    def test_run_allows_qwen_direct_answer_without_tool_call(self) -> None:
        class FakeFnCallAgent:
            def __init__(self, **_kwargs: Any) -> None:
                pass

            def run(self, **_kwargs: Any) -> Any:
                yield [{"role": "assistant", "content": "进入下一步"}]

        factory = AgentFactory(Settings(), ConnectionManager())
        with patch("qwen_agent.agents.FnCallAgent", FakeFnCallAgent):
            result = factory.run(
                "session-1",
                "request-1",
                [{"role": "user", "content": "你好"}],
                ["delegate_deepseek"],
            )
        self.assertEqual(result.answer, "进入下一步")

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
        factory = AgentFactory(Settings(), ConnectionManager())
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
