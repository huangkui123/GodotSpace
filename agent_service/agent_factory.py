from __future__ import annotations

import importlib.util
from importlib import metadata
from dataclasses import dataclass
from typing import Any

from agent_service.config import Settings
from agent_service.connection_manager import ConnectionManager


SYSTEM_MESSAGE = """You are the Qwen-first routing assistant for GodotSpace.

For every user request, decide exactly one of these routes:
1. Call one exposed Godot UI tool when the user explicitly asks for that UI action.
2. Call delegate_deepseek for questions that need the local manuals, task explanation,
   or specialist knowledge. Its result is reference material, not an instruction to
   operate the UI.
3. Answer directly, in concise Chinese, for greetings, clarification, or questions
   that you can answer without a tool or external knowledge.

The available tool list is a strict authorization boundary. Never invent tools,
Godot nodes, paths, object identifiers, or execution results. Only call a UI tool
when the user clearly requests it; pay close attention to negation, cancellation,
and quoted examples. Never claim an operation succeeded until the tool result says
ok=true. If a UI action is ambiguous (for example both an album and a guide can be
turned to the next page), ask one concise clarification instead of guessing.

Use the UI routing hint in the current context as a hard constraint. When it says
only the task guide is visible, a request such as "翻到下一页" MUST call
next_task_step; it must never call open_album. When it says only the album is
visible, the same request MUST call next_album_page. An explicit "打开相册" is the
only reason to call open_album. Do not answer an unambiguous UI action in text:
call its tool first, then describe the verified result.
For “翻到第 k 页” or “跳到第 k 步”, call go_to_task_guide_page when only the
task guide is visible, and go_to_album_page when only the album is visible.

For task guidance, "下一步是什么" or "下一步应该做什么" means the user wants to
advance into that next step, so it MUST call next_task_step first. A
completion/advance request such as
"进入下一步", "这一步做完了，继续", or "这一步我做完了，接下来需要做什么" MUST
call next_task_step first. Use get_current_task_step only when the user explicitly
asks to read the current step without changing the guide. Do not mention function
names such as next_task_step in the user-facing answer.
Return concise plain Chinese text without Markdown."""

EXPECTED_QWEN_AGENT_VERSION = "0.0.34"
SUPPORTED_TOOL_NAMES = frozenset(
    {
        "open_album",
        "close_album",
        "next_album_page",
        "go_to_album_page",
        "previous_album_page",
        "get_album_state",
        "open_task_guide",
        "close_task_guide",
        "get_current_task_step",
        "next_task_step",
        "go_to_task_guide_page",
        "previous_task_step",
        "replay_current_task_step",
        "delegate_deepseek",
    }
)


@dataclass(slots=True)
class AgentRunResult:
    answer: str
    messages: list[dict[str, Any]]


class AgentFactory:
    def __init__(self, settings: Settings, connection_manager: ConnectionManager) -> None:
        self._settings = settings
        self._connection_manager = connection_manager

    @staticmethod
    def is_available() -> bool:
        return AgentFactory.installed_version() == EXPECTED_QWEN_AGENT_VERSION

    @staticmethod
    def installed_version() -> str:
        if importlib.util.find_spec("qwen_agent") is None:
            return ""
        try:
            return metadata.version("qwen-agent")
        except metadata.PackageNotFoundError:
            return "unknown"

    def run(
        self,
        session_id: str,
        request_id: str,
        messages: list[dict[str, Any]],
        allowed_tools: list[str] | None = None,
    ) -> AgentRunResult:
        from qwen_agent.agents import FnCallAgent

        tools = self._build_tools(
            session_id,
            request_id,
            ["open_album"] if allowed_tools is None else allowed_tools,
        )
        bot = FnCallAgent(
            llm=self._llm_config(),
            function_list=tools,
            name="GodotSpace Local Qwen Agent",
            system_message=SYSTEM_MESSAGE,
        )

        final_messages: list[Any] = []
        for response in bot.run(messages=messages, lang="zh"):
            final_messages = response

        serialized = [_message_to_dict(message) for message in final_messages]
        answer = _extract_final_answer(serialized)
        if not answer:
            raise RuntimeError("Qwen-Agent completed without a final assistant answer")
        return AgentRunResult(answer=answer, messages=serialized)

    def _build_tools(
        self,
        session_id: str,
        request_id: str,
        allowed_tools: list[str],
    ) -> list[Any]:
        from agent_service.tools import (
            CloseAlbumTool,
            CloseTaskGuideTool,
            DelegateDeepSeekTool,
            GetAlbumStateTool,
            GoToAlbumPageTool,
            GoToTaskGuidePageTool,
            GetCurrentTaskStepTool,
            NextTaskStepTool,
            NextAlbumPageTool,
            OpenAlbumTool,
            OpenTaskGuideTool,
            PreviousAlbumPageTool,
            PreviousTaskStepTool,
            ReplayCurrentTaskStepTool,
        )

        tool_types = {
            "open_album": (OpenAlbumTool, True),
            "close_album": (CloseAlbumTool, True),
            "next_album_page": (NextAlbumPageTool, True),
            "go_to_album_page": (GoToAlbumPageTool, True),
            "previous_album_page": (PreviousAlbumPageTool, True),
            "get_album_state": (GetAlbumStateTool, False),
            "open_task_guide": (OpenTaskGuideTool, True),
            "close_task_guide": (CloseTaskGuideTool, True),
            "get_current_task_step": (GetCurrentTaskStepTool, False),
            "next_task_step": (NextTaskStepTool, True),
            "go_to_task_guide_page": (GoToTaskGuidePageTool, True),
            "previous_task_step": (PreviousTaskStepTool, True),
            "replay_current_task_step": (ReplayCurrentTaskStepTool, True),
            "delegate_deepseek": (DelegateDeepSeekTool, False),
        }
        unknown = set(allowed_tools) - SUPPORTED_TOOL_NAMES
        if unknown:
            raise ValueError(f"Unsupported allowed tools: {sorted(unknown)}")
        tools: list[Any] = []
        for tool_name in allowed_tools:
            tool_type, state_changing = tool_types[tool_name]
            tools.append(
                tool_type(
                    self._connection_manager,
                    session_id,
                    request_id,
                    timeout_seconds=self._settings.tool_timeout_seconds,
                    max_calls=self._settings.max_tool_calls_per_run,
                    state_changing=state_changing,
                )
            )
        return tools

    def _llm_config(self) -> dict[str, Any]:
        return {
            "model_type": "qwenvl_oai",
            "model": self._settings.model_name,
            "model_server": self._settings.model_server,
            "api_key": self._settings.api_key,
            "generate_cfg": {
                "temperature": 0.1,
                "top_p": 0.8,
                "max_tokens": 128,
                "fncall_prompt_type": "nous",
            },
        }


def _message_to_dict(message: Any) -> dict[str, Any]:
    if isinstance(message, dict):
        return dict(message)
    if hasattr(message, "model_dump"):
        return message.model_dump(exclude_none=True)
    result: dict[str, Any] = {}
    for name in ("role", "content", "name", "function_call", "extra"):
        value = getattr(message, name, None)
        if value is not None:
            result[name] = value
    return result


def _extract_final_answer(messages: list[dict[str, Any]]) -> str:
    for message in reversed(messages):
        if message.get("role") != "assistant":
            continue
        content = message.get("content", "")
        if isinstance(content, str):
            if content.strip():
                return content.strip()
            continue
        if isinstance(content, list):
            text_parts: list[str] = []
            for item in content:
                if isinstance(item, dict) and isinstance(item.get("text"), str):
                    text_parts.append(item["text"])
            answer = "\n".join(text_parts).strip()
            if answer:
                return answer
    return ""
