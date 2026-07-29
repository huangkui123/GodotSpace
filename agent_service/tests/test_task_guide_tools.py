from __future__ import annotations

import importlib.util
import json
import unittest
from typing import Any


class FakeConnectionManager:
    def __init__(self) -> None:
        self.calls: list[dict[str, Any]] = []

    def request_tool_sync(self, **kwargs: Any) -> dict[str, Any]:
        self.calls.append(kwargs)
        return {"ok": True, "data": kwargs["arguments"], "error": None}


@unittest.skipUnless(
    importlib.util.find_spec("qwen_agent") is not None,
    "qwen_agent is not installed in this Python environment",
)
class TaskGuideToolTests(unittest.TestCase):
    def _make_tool(self, tool_type: type[Any], *, state_changing: bool) -> Any:
        manager = FakeConnectionManager()
        tool = tool_type(
            manager,
            "session-1",
            "request-1",
            timeout_seconds=1.0,
            max_calls=2,
            state_changing=state_changing,
        )
        return manager, tool

    def test_open_task_accepts_only_enabled_integer_id(self) -> None:
        from jsonschema import ValidationError

        from agent_service.tools import OpenTaskGuideTool

        manager, tool = self._make_tool(OpenTaskGuideTool, state_changing=True)
        self.assertTrue(json.loads(tool.call('{"task_id": 1}'))["ok"])
        self.assertEqual(manager.calls[0]["arguments"], {"task_id": 1})
        for invalid in ('{"task_id": 2}', '{"task_id": true}', '{"path": "/root"}'):
            with self.subTest(invalid=invalid):
                with self.assertRaises(ValidationError):
                    tool.call(invalid)

    def test_current_step_is_parameterless_and_read_only(self) -> None:
        from agent_service.tools import GetCurrentTaskStepTool

        manager, tool = self._make_tool(
            GetCurrentTaskStepTool, state_changing=False
        )
        json.loads(tool.call("{}"))
        self.assertEqual(manager.calls[0]["arguments"], {})
        self.assertFalse(manager.calls[0]["state_changing"])
        with self.assertRaises(ValueError):
            tool.call('{"advance": true}')

    def test_next_step_has_no_model_supplied_preconditions(self) -> None:
        from agent_service.tools import NextTaskStepTool

        manager, tool = self._make_tool(NextTaskStepTool, state_changing=True)
        json.loads(tool.call("{}"))
        self.assertEqual(manager.calls[0]["arguments"], {})
        self.assertTrue(manager.calls[0]["state_changing"])
        with self.assertRaises(ValueError):
            tool.call('{"expected_page_index": 4}')

    def test_direct_page_normalizes_explicit_chinese_ordinal(self) -> None:
        from agent_service.tools import GoToTaskGuidePageTool

        manager, tool = self._make_tool(
            GoToTaskGuidePageTool, state_changing=True
        )
        for value in (3, 3.0, "3", "三", "第三页"):
            with self.subTest(value=value):
                json.loads(tool.call({"page": value}))
                self.assertEqual(manager.calls[-1]["arguments"], {"page": 3})
        for value in (True, 0, -1, "第三章", "abc"):
            with self.subTest(invalid=value):
                with self.assertRaises(ValueError):
                    tool.call({"page": value})


if __name__ == "__main__":
    unittest.main()
