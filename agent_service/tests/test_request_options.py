from __future__ import annotations

import unittest

from agent_service.app import (
    _build_stateless_user_message,
    _parse_agent_request_options,
)
from agent_service.protocol import ProtocolError


class RequestOptionsTests(unittest.TestCase):
    def test_defaults_to_album_only_without_context(self) -> None:
        context, allowed_tools, conversation_id = _parse_agent_request_options({}, 100)
        self.assertEqual(context, {})
        self.assertEqual(allowed_tools, ["open_album"])
        self.assertEqual(conversation_id, "default")

    def test_accepts_task_context_and_bounded_tool_authorization(self) -> None:
        context, allowed_tools, conversation_id = _parse_agent_request_options(
            {
                "context": {"task_id": 1, "page_index": 2},
                "allowed_tools": [
                    "open_task_guide",
                    "get_current_task_step",
                    "next_task_step",
                ],
                "conversation_id": "speaker-7",
            },
            200,
        )
        self.assertEqual(context["page_index"], 2)
        self.assertEqual(allowed_tools[-1], "next_task_step")
        self.assertEqual(conversation_id, "speaker-7")

    def test_rejects_unknown_or_duplicate_authorization(self) -> None:
        for allowed_tools in (["call_node"], ["open_album", "open_album"]):
            with self.subTest(allowed_tools=allowed_tools):
                with self.assertRaises(ProtocolError):
                    _parse_agent_request_options(
                        {"allowed_tools": allowed_tools}, 200
                    )

    def test_rejects_oversized_context(self) -> None:
        with self.assertRaises(ProtocolError):
            _parse_agent_request_options({"context": {"text": "12345"}}, 4)

    def test_context_is_embedded_in_one_current_request_message(self) -> None:
        message = _build_stateless_user_message(
            "下一步应该做什么",
            {
                "ui_routing_hint": {
                    "visible_panel": "task_guide",
                    "page_turn_target_when_user_omits_target": "next_task_step",
                },
                "task_guide": {
                    "visible": True,
                    "task_id": 1,
                    "task_title": "无容器样品实验流程",
                    "page_index": 2,
                    "page_count": 5,
                    "current_step": {"title": "当前步骤", "info": "x" * 1000},
                },
            },
        )
        self.assertEqual(message["role"], "user")
        self.assertIn("下一步应该做什么", message["content"])
        self.assertIn('"page_index":2', message["content"])
        self.assertIn('"task_title":"无容器样品实验流程"', message["content"])
        self.assertIn('"visible_panels":["task_guide"]', message["content"])
        self.assertNotIn("ui_routing_hint", message["content"])
        self.assertNotIn("current_step", message["content"])
        self.assertNotIn("next_task_step", message["content"])
        self.assertNotIn("speaker_peer_id", message["content"])


if __name__ == "__main__":
    unittest.main()
