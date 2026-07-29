from __future__ import annotations

from typing import Any

from agent_service.tools.godot_rpc_tool import GodotRpcTool


class OpenAlbumTool(GodotRpcTool):
    name = "open_album"
    description = (
        "打开 GodotSpace 相册界面，可选显示指定页并刷新相册数据；"
        "它不负责已打开相册的向前或向后翻页。"
    )
    parameters = {
        "type": "object",
        "properties": {
            "page": {
                "type": "integer",
                "minimum": 1,
                "description": "打开后显示的相册页码，从 1 开始。",
            },
            "refresh": {
                "type": "boolean",
                "description": "显示前是否刷新相册数据。",
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
