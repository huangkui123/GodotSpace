from __future__ import annotations

from typing import Any

from agent_service.tools.godot_rpc_tool import GodotRpcTool


class OpenTaskGuideTool(GodotRpcTool):
    name = "open_task_guide"
    description = (
        "Open the enabled GodotSpace task guide. Use this only when the user "
        "explicitly asks to open or show the named guide. The MVP exposes only "
        "task_id 1, 无容器样品实验流程."
    )
    parameters = {
        "type": "object",
        "properties": {
            "task_id": {
                "type": "integer",
                "enum": [1],
                "description": "Stable enabled task ID. 1 is 无容器样品实验流程.",
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
        "Read the currently open task step without changing the task page. Use only "
        "when the user explicitly asks to read or repeat the current step."
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
        "Advance the active task exactly one step. Use this for an explicit "
        "command such as 进入下一步, 这一步做完了，继续, or 这一步我做完了，接下来需要做什么. "
        "If the task guide is the only visible paged panel, 翻到下一页, 下一步是什么, "
        "or 下一步应该做什么 also mean this tool."
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
        "Turn the visible task guide directly to the requested 1-based page/step number. "
        "Use for a request such as 翻到第3页 or 跳到第3步."
    )
    parameters = {
        "type": "object",
        "properties": {
            "page": {
                "type": "integer",
                "minimum": 1,
                "description": "The 1-based task guide page requested by the user.",
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
