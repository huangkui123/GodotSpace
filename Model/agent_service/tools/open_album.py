from __future__ import annotations

import json
from typing import Any

from agent_service.tools.godot_rpc_tool import GodotRpcTool
from agent_service.tools.page_number import parse_positive_page


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
        if isinstance(params, str):
            try:
                arguments = json.loads(params)
            except json.JSONDecodeError as exc:
                raise ValueError("Parameters must be formatted as valid JSON") from exc
        else:
            arguments = params
        if not isinstance(arguments, dict):
            raise ValueError("open_album parameters must be a JSON object")
        unknown = set(arguments) - {"page", "refresh"}
        if unknown:
            raise ValueError(f"Unknown open_album parameters: {sorted(unknown)}")
        page = parse_positive_page(arguments.get("page", 1))
        if page is None:
            raise ValueError("page must identify a positive integer page")
        refresh = arguments.get("refresh", True)
        if not isinstance(refresh, bool):
            raise ValueError("refresh must be a boolean")
        normalized = {
            "page": page,
            "refresh": refresh,
        }
        return self.call_godot(normalized)
