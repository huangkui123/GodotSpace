from __future__ import annotations

from typing import Any

from agent_service.tools.godot_rpc_tool import GodotRpcTool


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
    description = "Close the currently visible photo album. Use only for an explicit close/hide album request."


class NextAlbumPageTool(_EmptyArgumentsTool):
    name = "next_album_page"
    description = "Turn the visible photo album forward exactly one page."


class GoToAlbumPageTool(GodotRpcTool):
    name = "go_to_album_page"
    description = "Turn the visible photo album directly to the requested 1-based page number."
    parameters = {
        "type": "object",
        "properties": {
            "page": {
                "type": "integer",
                "minimum": 1,
                "description": "The 1-based album page requested by the user.",
            }
        },
        "required": ["page"],
    }

    def call(self, params: str | dict[str, Any], **kwargs: Any) -> str:
        arguments = self._verify_json_format_args(params, strict_json=True)
        if set(arguments) != {"page"}:
            raise ValueError("go_to_album_page requires only an integer page parameter")
        page = arguments["page"]
        if not isinstance(page, int) or isinstance(page, bool) or page < 1:
            raise ValueError("page must be an integer greater than zero")
        return self.call_godot({"page": page})


class PreviousAlbumPageTool(_EmptyArgumentsTool):
    name = "previous_album_page"
    description = "Turn the visible photo album back exactly one page."


class GetAlbumStateTool(_EmptyArgumentsTool):
    name = "get_album_state"
    description = "Read the visible photo album page and navigation state without changing it."


class CloseTaskGuideTool(_EmptyArgumentsTool):
    name = "close_task_guide"
    description = "Close the currently visible task guide."


class PreviousTaskStepTool(_EmptyArgumentsTool):
    name = "previous_task_step"
    description = "Move the visible task guide back exactly one step."


class ReplayCurrentTaskStepTool(_EmptyArgumentsTool):
    name = "replay_current_task_step"
    description = "Replay the current task step animation."


class DelegateDeepSeekTool(_EmptyArgumentsTool):
    name = "delegate_deepseek"
    description = (
        "Ask the configured DeepSeek specialist with local manual knowledge and the current "
        "sanitized UI snapshot. Use for how-to, manual, or expert questions, not UI actions."
    )
