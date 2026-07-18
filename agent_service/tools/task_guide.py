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
        "Read the currently open task step and the next-step preview without "
        "changing the task page. Questions such as 下一步是什么 or 下一步应该做什么 "
        "must use this read-only tool and must never advance the task."
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
        "Advance the active task exactly one step. Use this only for an explicit "
        "command such as 进入下一步 or 这一步做完了，继续. Never use it for a "
        "question such as 下一步是什么 or 下一步应该做什么."
    )
    parameters = {"type": "object", "properties": {}, "required": []}

    def call(self, params: str | dict[str, Any], **kwargs: Any) -> str:
        arguments = self._verify_json_format_args(params, strict_json=True)
        if arguments:
            raise ValueError("next_task_step does not accept parameters")
        return self.call_godot({})
