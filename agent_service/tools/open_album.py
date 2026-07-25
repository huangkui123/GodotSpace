from __future__ import annotations

from typing import Any

from agent_service.tools.godot_rpc_tool import GodotRpcTool


class OpenAlbumTool(GodotRpcTool):
    name = "open_album"
    description = (
        "Open the photo album UI in GodotSpace. Use this only when the user explicitly "
        "asks to open, show, or view the album or photos. Never use it merely to turn "
        "a page; use next_album_page or previous_album_page for an already visible album. "
        "Never use it when the user negates or cancels that action. Repeated calls are safe."
    )
    parameters = {
        "type": "object",
        "properties": {
            "page": {
                "type": "integer",
                "minimum": 1,
                "description": "Album page to show, starting from 1.",
            },
            "refresh": {
                "type": "boolean",
                "description": "Refresh the album data before showing it.",
            },
        },
        "required": [],
    }

    def call(self, params: str | dict[str, Any], **kwargs: Any) -> str:
        arguments = self._verify_json_format_args(params, strict_json=True)
        unknown = set(arguments) - {"page", "refresh"}
        if unknown:
            raise ValueError(f"Unknown open_album parameters: {sorted(unknown)}")
        normalized = {
            "page": int(arguments.get("page", 1)),
            "refresh": bool(arguments.get("refresh", True)),
        }
        return self.call_godot(normalized)
