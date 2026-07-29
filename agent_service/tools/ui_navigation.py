from __future__ import annotations

from typing import Any

from agent_service.tools.godot_rpc_tool import GodotRpcTool
from agent_service.tools.page_number import parse_page_arguments


class _EmptyArgumentsTool(GodotRpcTool):
    """A fixed UI action with no model-provided arguments."""

    parameters = {"type": "object", "properties": {}, "required": []}

    def call(self, params: str | dict[str, Any], **kwargs: Any) -> str:
        arguments = self._verify_json_format_args(params, strict_json=True)
        if arguments:
            raise ValueError(f"{self.name} does not accept parameters")
        return self.call_godot({})


class CloseAlbumTool(_EmptyArgumentsTool):
    name = "close_album"
    description = "关闭当前可见的相册界面，不影响实验指导书。"


class NextAlbumPageTool(_EmptyArgumentsTool):
    name = "next_album_page"
    description = (
        "将当前可见的相册向后翻一页，不影响实验指导书，也不接收目标页码。"
        "多个分页界面同时可见时，只有用户明确指向相册或照片才能选择它。"
    )


class GoToAlbumPageTool(GodotRpcTool):
    name = "go_to_album_page"
    description = (
        "仅在用户明确给出目标页码时，将当前可见的相册直接切换到该页，不影响"
        "实验指导书。用户已经同时说明“相册/照片”和目标页码时信息完整，应立即"
        "调用本工具，无需再次确认；页码是否存在由相册执行结果校验。多个分页界面"
        "同时可见时，用户还必须明确指向相册或照片。"
    )
    parameters = {
        "type": "object",
        "properties": {
            "page": {
                "type": "integer",
                "minimum": 1,
                "description": "相册目标页码，从 1 开始。",
            }
        },
        "required": ["page"],
    }

    def call(self, params: str | dict[str, Any], **kwargs: Any) -> str:
        return self.call_godot(
            parse_page_arguments(params, tool_name="go_to_album_page")
        )


class PreviousAlbumPageTool(_EmptyArgumentsTool):
    name = "previous_album_page"
    description = (
        "将当前可见的相册向前返回一页，不影响实验指导书。多个分页界面同时"
        "可见时，只有用户明确指向相册或照片才能选择它。"
    )


class GetAlbumStateTool(_EmptyArgumentsTool):
    name = "get_album_state"
    description = "读取当前相册页码和翻页状态，不改变相册。"


class CloseTaskGuideTool(_EmptyArgumentsTool):
    name = "close_task_guide"
    description = "关闭当前可见的实验指导书，不影响相册。"


class PreviousTaskStepTool(_EmptyArgumentsTool):
    name = "previous_task_step"
    description = (
        "将当前可见的实验指导书向前返回上一步或上一页，不影响相册，也不负责"
        "知识问答。多个分页界面同时可见时，只有用户明确指向任务、步骤或指导书"
        "才能选择它。"
    )


class ReplayCurrentTaskStepTool(_EmptyArgumentsTool):
    name = "replay_current_task_step"
    description = "重新播放当前实验指导步骤的动画，不改变指导书页码。"


class DelegateDeepSeekTool(_EmptyArgumentsTool):
    name = "delegate_deepseek"
    description = (
        "查询实验手册、当前步骤怎样操作、步骤含义或专业知识时，使用这个唯一的"
        "知识来源交给 DeepSeek 回答；不要由路由模型自行编造专业答案。该工具只"
        "回答知识问题，不打开、关闭或翻动任何 UI。“这一步在讲什么”属于当前"
        "步骤含义查询，应调用本工具。"
    )
