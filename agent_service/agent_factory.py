from __future__ import annotations

import importlib.util
from importlib import metadata
from dataclasses import dataclass
from typing import Any

from agent_service.config import Settings
from agent_service.connection_manager import ConnectionManager


SYSTEM_MESSAGE = """You are the local GodotSpace control assistant.

Your current responsibility is deliberately narrow: help with explicitly requested,
reversible UI actions exposed through the available tools. Use a tool only when the
user clearly asks for that action. Pay special attention to negation, cancellation,
and quoted examples. Never claim an action succeeded until its tool result says
ok=true. Do not invent tools, Godot nodes, paths, object identifiers, or execution
results. If a tool is unavailable or fails, explain that briefly in Chinese.

For task guidance, a question such as "下一步是什么" or "下一步应该做什么" is
read-only and must use get_current_task_step. Only an explicit command such as
"进入下一步" or "这一步做完了，继续" may use next_task_step. The available tool
list is an authorization boundary: never invent or request a tool that is absent.
Return the final answer as concise plain Chinese text without Markdown."""

EXPECTED_QWEN_AGENT_VERSION = "0.0.34"
SUPPORTED_TOOL_NAMES = frozenset(
    {
        "open_album",
        "open_task_guide",
        "get_current_task_step",
        "next_task_step",
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
            allowed_tools or ["open_album"],
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
            GetCurrentTaskStepTool,
            NextTaskStepTool,
            OpenAlbumTool,
            OpenTaskGuideTool,
        )

        tool_types = {
            "open_album": (OpenAlbumTool, True),
            "open_task_guide": (OpenTaskGuideTool, True),
            "get_current_task_step": (GetCurrentTaskStepTool, False),
            "next_task_step": (NextTaskStepTool, True),
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
                "max_tokens": 256,
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
