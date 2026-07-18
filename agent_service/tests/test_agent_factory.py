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


if __name__ == "__main__":
    unittest.main()
