from __future__ import annotations

import json
from typing import Any

from qwen_agent.tools.base import BaseTool


class _TextResponseTool(BaseTool):
    field_name = "text"
    parameters = {
        "type": "object",
        "properties": {
            "text": {
                "type": "string",
                "minLength": 1,
                "description": "向用户返回的简洁中文文本。",
            }
        },
        "required": ["text"],
    }

    def call(self, params: str | dict[str, Any], **kwargs: Any) -> str:
        arguments = self._verify_json_format_args(params, strict_json=True)
        if set(arguments) != {self.field_name}:
            raise ValueError(f"{self.name} requires only {self.field_name!r}")
        text = arguments[self.field_name]
        if not isinstance(text, str) or not text.strip():
            raise ValueError(f"{self.field_name} must be a non-empty string")
        return json.dumps(
            {"ok": True, "data": {"answer": text.strip()}, "error": None},
            ensure_ascii=False,
        )


class RespondDirectlyTool(_TextResponseTool):
    name = "respond_directly"
    description = (
        "仅用于问候、闲聊或无需 UI、实验手册和专业资料即可可靠回答的普通问题。"
        "它不能代替 UI 操作，也不能编造当前实验步骤的操作方法。"
    )


class ClarifyUITargetTool(_TextResponseTool):
    name = "clarify_ui_target"
    description = (
        "当相册和实验指导书等多个 UI 对象同时可执行同一操作，而用户没有说明"
        "操作对象，或给出的名称对多个对象同样接近时，用一句简洁中文询问用户要"
        "操作哪个对象；它不修改 UI。用户已经给出能唯一接近某个可操作对象的名称"
        "时，即使名称并非完全一致，也应选择那个对象的具体工具，让后续校验决定"
        "是否向用户确认，并把 semantic_context.target_source 设为 approximate，"
        "不应选择本工具。"
    )
