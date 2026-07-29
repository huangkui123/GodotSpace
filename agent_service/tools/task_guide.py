from __future__ import annotations

from typing import Any

from agent_service.tools.godot_rpc_tool import GodotRpcTool


class OpenTaskGuideTool(GodotRpcTool):
    name = "open_task_guide"
    description = (
        "打开 GodotSpace 中指定的实验指导书。当前只开放 task_id 1，"
        "即“无容器样品实验流程”。"
    )
    parameters = {
        "type": "object",
        "properties": {
            "task_id": {
                "type": "integer",
                "enum": [1],
                "description": "指导书 ID；当前只能是 1。",
            }
        },
        "required": ["task_id"],
    }

    def call(self, params: str | dict[str, Any], **kwargs: Any) -> str:
        arguments = self._verify_json_format_args(params, strict_json=True)
        unknown = set(arguments) - {"task_id"}
        if unknown:
            raise ValueError(f"Unknown open_task_guide parameters: {sorted(unknown)}")
        task_id = arguments.get("task_id")
        if not isinstance(task_id, int) or isinstance(task_id, bool) or task_id != 1:
            raise ValueError("task_id must be the enabled integer ID 1")
        return self.call_godot({"task_id": task_id})


class GetCurrentTaskStepTool(GodotRpcTool):
    name = "get_current_task_step"
    description = (
        "读取并返回当前实验指导书正在显示的步骤及其内容，不改变指导书页码；"
        "它不负责解释操作方法。"
    )
    parameters = {"type": "object", "properties": {}, "required": []}

    def call(self, params: str | dict[str, Any], **kwargs: Any) -> str:
        arguments = self._verify_json_format_args(params, strict_json=True)
        if arguments:
            raise ValueError("get_current_task_step does not accept parameters")
        return self.call_godot({})


class NextTaskStepTool(GodotRpcTool):
    name = "next_task_step"
    description = (
        "继续当前任务流程：将可见的实验指导书向后推进一个步骤，并显示推进后的"
        "步骤内容。用户表示当前步骤已经完成并希望继续流程时，也由它推进。"
        "它不影响相册，也不接收目标页码；多个分页界面同时可见时，只有用户明确"
        "指向任务、步骤或指导书才能选择它。"
    )
    parameters = {"type": "object", "properties": {}, "required": []}

    def call(self, params: str | dict[str, Any], **kwargs: Any) -> str:
        arguments = self._verify_json_format_args(params, strict_json=True)
        if arguments:
            raise ValueError("next_task_step does not accept parameters")
        return self.call_godot({})


class GoToTaskGuidePageTool(GodotRpcTool):
    name = "go_to_task_guide_page"
    description = (
        "仅在用户明确给出目标页码或步骤编号时，将当前可见的实验指导书直接切换"
        "到该页或步骤；不影响相册。多个分页界面同时可见时，用户还必须明确指向"
        "任务、步骤或指导书。"
    )
    parameters = {
        "type": "object",
        "properties": {
            "page": {
                "type": "integer",
                "minimum": 1,
                "description": "指导书目标页码或步骤编号，从 1 开始。",
            }
        },
        "required": ["page"],
    }

    def call(self, params: str | dict[str, Any], **kwargs: Any) -> str:
        arguments = self._verify_json_format_args(params, strict_json=True)
        if set(arguments) != {"page"}:
            raise ValueError("go_to_task_guide_page requires only an integer page parameter")
        page = arguments["page"]
        if not isinstance(page, int) or isinstance(page, bool) or page < 1:
            raise ValueError("page must be an integer greater than zero")
        return self.call_godot({"page": page})
