from __future__ import annotations

import importlib.util
import json
import unittest
from typing import Any

from agent_service.connection_manager import ConnectionManager


class FakeConnectionManager:
    def __init__(self) -> None:
        self.calls: list[dict[str, Any]] = []

    def request_tool_sync(self, **kwargs: Any) -> dict[str, Any]:
        self.calls.append(kwargs)
        return {
            "ok": True,
            "data": {"visible": True, "page": kwargs["arguments"]["page"]},
            "error": None,
        }


@unittest.skipUnless(
    importlib.util.find_spec("qwen_agent") is not None,
    "qwen_agent is not installed in this Python environment",
)
class OpenAlbumToolTests(unittest.TestCase):
    def test_defaults_are_normalized_before_rpc(self) -> None:
        from agent_service.tools.open_album import OpenAlbumTool

        manager = FakeConnectionManager()
        tool = OpenAlbumTool(
            manager,  # type: ignore[arg-type]
            "session-1",
            "request-1",
            timeout_seconds=1.0,
            max_calls=2,
        )
        result = json.loads(tool.call("{}"))
        self.assertTrue(result["ok"])
        self.assertEqual(
            manager.calls[0]["arguments"], {"page": 1, "refresh": True}
        )

    def test_unknown_parameter_is_rejected(self) -> None:
        from agent_service.tools.open_album import OpenAlbumTool

        tool = OpenAlbumTool(
            FakeConnectionManager(),  # type: ignore[arg-type]
            "session-1",
            "request-1",
            timeout_seconds=1.0,
            max_calls=2,
        )
        with self.assertRaises(ValueError):
            tool.call('{"node_path": "/root/Global"}')

    def test_disconnected_godot_returns_structured_rpc_error(self) -> None:
        from agent_service.tools.open_album import OpenAlbumTool

        tool = OpenAlbumTool(
            ConnectionManager(),
            "missing-session",
            "request-1",
            timeout_seconds=0.1,
            max_calls=1,
        )
        result = json.loads(tool.call("{}"))
        self.assertFalse(result["ok"])
        self.assertEqual(result["data"], {})
        self.assertEqual(result["error"]["code"], "target_offline")
        self.assertIn("not available", result["error"]["message"])


if __name__ == "__main__":
    unittest.main()
